# frozen_string_literal: true

module Sandcrawler
  class CLI
    module Devices
      private

      def picotool
        Acquisition::Picotool.new(executable: @options[:picotool], log: @log)
      end

      def run_doctor(_args)
        @log.warn("Preserve a BOOTSEL dump before using flash_nuke.uf2 or reinstalling firmware.")
        result = { ruby: RUBY_VERSION, platform: RUBY_PLATFORM, serialport: !Gem::Specification.find_all_by_name("serialport").empty? }
        begin
          tool = picotool
          result[:picotool] = { version: tool.version }
          begin
            result[:device] = tool.info
          rescue Error => e
            result[:device] = { available: false, detail: e.message }
          end
        rescue Error => e
          result[:picotool] = { available: false, detail: e.message }
        end
        if RUBY_PLATFORM.include?("linux")
          result[:usb_permissions] =
            "picotool info checks access; install the upstream udev rules if permission is denied"
        end
        emit(result) { result.each { |key, value| @stdout.puts("#{key}: #{value}") } }
        0
      end

      def run_dump(_args)
        result = picotool.dump(@options[:out], passes: @options[:passes], force: @options[:force])
        emit(result) { @stdout.puts("Preserved dump in #{@options[:out]}: #{result.dig(:result, :sha256)}") }
        result.dig(:result, :unstable_blocks).to_a.empty? ? 0 : 5
      end

      def run_copy(args)
        result = Acquisition::MountedVolume.new(args.first).copy(@options[:out], force: @options[:force], log: @log)
        emit(result) { @stdout.puts("Copied #{result[:files].size} files to #{@options[:out]}") }
        result_code(result)
      end

      def run_serial(_args)
        port = @options[:port] || select_port
        shell = Acquisition::SerialShell.new(port: port, log: @log)
        result = shell.copy(@options[:out], force: @options[:force], root: @options[:root] || "/")
        emit(result) { @stdout.puts("Transferred #{result[:files].size} files to #{@options[:out]}") }
        result_code(result)
      end

      def select_port
        ports = Acquisition::SerialShell.ports
        raise DeviceNotFoundError, "No serial ports found; pass --port for R2P2 CDC0" if ports.empty?

        @stderr.puts("Choose R2P2 CDC0 (shell), not CDC1/CDC2:")
        ports.each_with_index { |port, i| @stderr.puts("#{i + 1}: #{port}") }
        index = number(prompt("Port number")) - 1
        raise UsageError, "Invalid serial port selection" unless index.between?(0, ports.size - 1)

        ports[index]
      end

      def run_auto(_args)
        base = @options[:out]
        raise SafetyError, "Output is a symlink: #{base}" if File.symlink?(base)
        if File.exist?(base) && (!File.directory?(base) || (!@options[:force] && !Dir.empty?(base)))
          raise SafetyError, "Output must be an empty directory (or use --force): #{base}"
        end

        route = prompt("Recovery route: [a] BOOTSEL (recommended), [b] mounted volume, [c] serial",
                       default: "a").downcase
        raise UsageError, "Choose a, b, or c" unless %w[a b c].include?(route)

        @options[:out] = File.join(base, "acquisition") if route == "a"
        code = case route
               when "a"
                 dump = picotool.dump(@options[:out], passes: @options[:passes], force: @options[:force])
                 unless dump.dig(:result, :unstable_blocks).to_a.empty?
                   emit(dump) { @stdout.puts("Dump contains unstable blocks; inspect dump.json before recovery") }
                   return 5
                 end

                 image = File.join(@options[:out], "dump.bin")
                 @options[:out] = File.join(base, "recovered")
                 run_extract([image])
               when "b"
                 run_copy([prompt("Mounted R2P2 directory")])
               when "c"
                 run_serial([])
               end
        code
      ensure
        @stderr.puts("Check the dump and recovered files before erasing or reinstalling R2P2. Keep dump.bin.")
      end

      def prompt(message, default: nil)
        @stderr.print("#{message}: ")
        input = @stdin.gets
        raise UsageError, "Interactive input required; use an explicit command for unattended operation" unless input

        value = input.strip
        value.empty? && default ? default : value
      end
    end
  end
end
