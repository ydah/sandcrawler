# frozen_string_literal: true

require "open3"
require "tempfile"
require "digest"
require "json"
require "time"

module Sandcrawler
  module Acquisition
    class Picotool
      COMMANDS = %w[version info save].freeze
      FLASH_BASE = 0x10000000
      BLOCK_SIZE = 4096
      MAX_OUTPUT_BYTES = 1024 * 1024

      def initialize(executable: nil, log: nil, timeout: 120)
        unless timeout.is_a?(Numeric) && timeout.positive? && timeout.finite?
          raise UsageError, "Picotool timeout must be finite and positive"
        end

        @executable = executable || ENV["PICOTOOL"] || "picotool"
        @log = log
        @timeout = timeout
      end

      def run(command, *arguments)
        validate_command(command, arguments)
        stdout, stderr, status = capture(command, arguments)
        return stdout.b if status.success?

        detail = [stdout.b, stderr.b].reject(&:empty?).join("\n").strip
        missing = detail.match?(/no .*devices|device.*not found|unable to connect|no accessible/i)
        error = missing ? DeviceNotFoundError : Error
        raise error, "picotool #{command}: #{detail}"
      rescue Errno::ENOENT
        raise DeviceNotFoundError, "picotool not found; install picotool 2.x or use --picotool PATH"
      end

      def version
        run("version").strip
      end

      def info
        raw = run("info", "-a")
        match = raw.match(/flash\s+size\s*:\s*(\d+(?:\.\d+)?)\s*([KMGT](?:i?B|bytes?)?|bytes?)?/i)
        multiplier = match && { "K" => 1024, "M" => 1024**2, "G" => 1024**3, "T" => 1024**4 }.fetch(
          match[2].to_s[0]&.upcase, 1
        )
        { raw: raw, chip: raw[/\bRP(?:2040|2350)\b/i]&.upcase,
          flash_size: match && (match[1].to_f * multiplier).to_i }
      end

      def dump(out, passes: 2, force: false)
        raise UsageError, "--passes must be an integer of at least 2" unless passes.is_a?(Integer) && passes >= 2

        tool_version = version
        device = info
        output = Extractor.new(out, source: { type: "picotool", executable: @executable }, force: force, log: @log)
        records = []
        passes.times { records << save_pass(output, records.length + 1, device[:flash_size]) }
        if records.map { |record| record[:sha256] }.uniq.length > 1
          records << save_pass(output, records.length + 1, device[:flash_size])
        end
        validate_sizes!(records, device[:flash_size])
        data, unstable = combine(output, records)
        result = output.write(path: "dump.bin", data: data, category: nil, status: unstable.empty? ? "ok" : "unstable")
        verify_output!(result)
        File.chmod(0o444, File.join(output.out, result[:output]))
        unless unstable.empty?
          output.warning("UNSTABLE_BLOCKS",
                         "No strict majority for block offsets: #{unstable.join(', ')}")
        end
        metadata = {
          tool: "sandcrawler", tool_version: VERSION, created_at: Time.now.iso8601,
          picotool: { version: tool_version, info: device[:raw] },
          device: device.except(:raw), passes: records,
          result: { file: result[:output], sha256: result[:sha256], unstable_blocks: unstable }
        }
        metadata = Manifest.json_safe(metadata)
        verify_output!(output.write(path: "dump.bin.sha256", data: "#{result[:sha256]}  #{result[:output]}\n",
                                    category: nil))
        verify_output!(output.write(path: "dump.json", data: "#{JSON.pretty_generate(metadata)}\n", category: nil))
        output.finish
        metadata
      rescue Error, IOError, SystemCallError => e
        if output
          output.warning("DUMP_FAILED", e.message)
          output.finish
        end
        raise
      end

      private

      def capture(command, arguments)
        Open3.popen3(@executable, command, *arguments) do |input, output, errors, process|
          input.close
          readers = [output, errors].map do |stream|
            Thread.new do
              text = stream.binmode.read(MAX_OUTPUT_BYTES + 1) || "".b
              stop_process(process) if text.bytesize > MAX_OUTPUT_BYTES
              text
            end
          end
          unless process.join(@timeout)
            stop_process(process)
            raise IntegrityError, "picotool #{command} timed out after #{@timeout} seconds"
          end
          unless readers.all? { |reader| reader.join(1) }
            raise IntegrityError, "picotool #{command} did not close its output streams"
          end

          captured = readers.map(&:value)
          if captured.any? { |text| text.bytesize > MAX_OUTPUT_BYTES }
            raise IntegrityError, "picotool #{command} exceeded the 1 MiB output limit"
          end

          [*captured, process.value]
        ensure
          readers&.each { |reader| reader.kill if reader.alive? }
        end
      end

      def stop_process(process)
        Process.kill("TERM", process.pid)
        Process.kill("KILL", process.pid) unless process.join(1)
      rescue Errno::ESRCH
        nil
      end

      def validate_command(command, args)
        raise SafetyError, "picotool command is not read-only: #{command}" unless COMMANDS.include?(command)
        raise SafetyError, "Picotool arguments must be strings" unless args.all?(String)

        allowed = case command
                  when "version" then args.empty?
                  when "info" then args.empty? || args == ["-a"]
                  when "save"
                    valid_all = args.size == 5 && args[0, 2] == %w[-a -v] && safe_filename?(args[2])
                    valid_range = args.size == 7 && args[0] == "-r" && args[3] == "-v" &&
                                  args[1, 2].all? { |a| a.match?(/\A0x[0-9a-f]+\z/i) } && safe_filename?(args[4])
                    (valid_all || valid_range) && args[-2, 2] == %w[-t bin]
                  end
        raise SafetyError, "Unsupported picotool arguments; reboot and write options are forbidden" unless allowed
      end

      def safe_filename?(path)
        path.is_a?(String) && !path.empty? && !path.start_with?("-") && !path.include?("\0")
      end

      def save_pass(output, number, flash_size)
        Tempfile.create(["sandcrawler-pass", ".bin"]) do |temp|
          path = temp.path
          temp.close
          begin
            run("save", "-a", "-v", path, "-t", "bin")
          rescue Error => e
            preserve_failed_pass(output, path, number, "all", e)
            raise if e.is_a?(DeviceNotFoundError) || !flash_size&.positive?

            File.truncate(path, 0)
            begin
              run("save", "-r", format("0x%x", FLASH_BASE), format("0x%x", FLASH_BASE + flash_size), "-v", path, "-t",
                  "bin")
            rescue Error => range_error
              preserve_failed_pass(output, path, number, "range", range_error)
              raise
            end
          end
          record = File.open(path, "rb") do |file|
            output.write(path: "pass#{number}.bin", data: file, category: nil)
          end
          verify_output!(record)
          File.chmod(0o444, File.join(output.out, record[:output]))
          { file: record[:output], sha256: record[:sha256], size: record[:size] }
        end
      end

      def preserve_failed_pass(output, path, number, mode, error)
        output.warning("SAVE_FAILED", "Pass #{number} (#{mode}): #{error.message}")
        return unless File.file?(path) && File.size(path).positive?

        record = File.open(path, "rb") do |file|
          output.write(path: "pass#{number}-#{mode}-failed.bin", data: file, category: nil,
                       status: "acquisition_error", error: error.message)
        end
        verify_output!(record)
        File.chmod(0o444, File.join(output.out, record[:output]))
      end

      def verify_output!(record)
        return if record[:output] && %w[ok unstable acquisition_error].include?(record[:status])

        raise IntegrityError, "Could not preserve #{record[:path]}"
      end

      def validate_sizes!(records, expected)
        sizes = records.map { |record| record[:size] }
        return if sizes.uniq.size == 1 && sizes.first.positive? && (!expected || sizes.first == expected)

        raise IntegrityError,
              "Dump lengths #{sizes.inspect} do not match#{expected ? " flash size #{expected}" : ' each other'}"
      end

      def combine(output, records)
        images = records.map { |record| File.open(File.join(output.out, record[:file]), "rb") }
        data = +"".b
        unstable = []
        (0...records.first[:size]).step(BLOCK_SIZE) do |offset|
          blocks = images.map { |file| file.read(BLOCK_SIZE) }
          expected = [BLOCK_SIZE, records.first[:size] - offset].min
          unless blocks.all? { |block| block&.bytesize == expected }
            raise IntegrityError, "Preserved pass length changed at offset #{offset}"
          end

          winner, count = blocks.tally.max_by { |_block, votes| votes }
          unstable << offset unless count > records.length / 2
          data << winner
        end
        [data, unstable]
      ensure
        images&.each(&:close)
      end
    end
  end
end
