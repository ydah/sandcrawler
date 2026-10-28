# frozen_string_literal: true

require "open3"
require_relative "serial_templates"
require_relative "serial_protocol"

module Sandcrawler
  module Acquisition
    class SerialShell
      include SerialProtocol

      def self.ports
        if Gem.win_platform?
          stdout, _stderr, status = Open3.capture3(
            "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
            "[System.IO.Ports.SerialPort]::GetPortNames()"
          )
          return status.success? ? stdout.lines.map(&:strip).grep(/\ACOM\d+\z/i).uniq.sort : []
        end

        Dir.glob(%w[/dev/ttyACM* /dev/ttyUSB* /dev/cu.usbmodem* /dev/cu.usbserial*])
      rescue Errno::ENOENT
        []
      end

      def initialize(port: nil, io: nil, baud: 115_200, timeout: 10, log: nil)
        raise UsageError, "Serial timeout must be positive" unless timeout.is_a?(Numeric) && timeout.positive?
        raise UsageError, "Serial baud rate must be a positive integer" unless baud.is_a?(Integer) && baud.positive?

        @port = port
        @io = io
        @baud = baud
        @timeout = timeout
        @log = log
        @buffer = +"".b
      end

      def copy(out, force: false, root: "/")
        unless root.start_with?("/") && !root.include?("\0")
          raise UsageError,
                "Serial root must be an absolute path without NUL"
        end

        output = Extractor.new(out, source: { type: "serial", port: @port, root: root }, force: force, log: @log)
        connect
        @io.write("\x03\n")
        wait_prompt
        @io.write("irb\n")
        wait_prompt
        @entered_irb = true
        capabilities = probe(root)
        output.warning("SERIAL_CAPABILITIES", capabilities.inspect)
        copy_tree(output, root.sub(%r{/+\z}, ""), capabilities)
        output.finish
      rescue Error, SystemCallError, IOError => e
        output&.warning("SERIAL_FAILED", e.message)
        output&.finish
        raise
      ensure
        begin
          @io&.write("exit\n") if @entered_irb
        rescue IOError, SystemCallError
          nil
        end
        @io&.close if @owns_io
      end

      private

      def connect
        return if @io
        unless @port
          raise UsageError,
                "Select CDC0 with --port PORT (Windows: --port COM3). Candidates: #{self.class.ports.join(', ')}"
        end

        require "serialport"
        @io = SerialPort.new(@port, @baud, 8, 1, SerialPort::NONE)
        @owns_io = true
      rescue LoadError
        raise UsageError, "Serial support needs the optional dependency: gem install serialport"
      rescue Errno::ENOENT, Errno::ENODEV
        raise DeviceNotFoundError, "Serial port not found: #{@port}"
      end

      def probe(root)
        records = request(expected: "CAP") { |marker| SerialTemplates.capabilities(root, marker) }
        cap = records.find { |record| record[0] == "CAP" }
        unless records.size == 1 && cap&.size == 4 && %w[entries
                                                         open].include?(cap[1]) && %w[directory
                                                                                      stat].include?(cap[2]) &&
               %w[bytes each_byte].include?(cap[3])
          raise FormatError, "R2P2 does not provide the required read-only file APIs"
        end

        { list: cap[1], directory: cap[2], bytes: cap[3] }
      end

      def copy_tree(output, root, capabilities)
        queue = [[root.empty? ? "/" : root, ""]]
        visited = {}
        until queue.empty?
          remote, relative = queue.shift
          next if visited[remote]

          visited[remote] = true
          begin
            records = request(expected: "LIST") { |marker| SerialTemplates.listing(remote, capabilities, marker) }
            decode_listing(records).each do |record|
              name = decode_name(record[2])
              path = [relative, name].reject(&:empty?).join("/")
              full_path = "#{remote.sub(%r{/+\z}, '')}/#{name}"
              if record[1] == "D"
                queue << [full_path, path] if output.directory(path: path)
              elsif record[1] == "F"
                copy_file(output, full_path, path, capabilities)
              else
                raise FormatError, "Invalid serial entry type"
              end
            end
          rescue Error, IOError, SystemCallError => e
            output.warning("LIST_FAILED", "#{remote}: #{e.message}")
          end
        end
      end

      def decode_name(hex)
        raise FormatError, "Invalid filename hex" unless hex&.match?(/\A(?:[0-9a-f]{2})+\z/i)

        name = [hex].pack("H*").force_encoding(Encoding::UTF_8)
        unless name.valid_encoding? && !%w[. ..].include?(name) && !name.match?(%r{[/\\\x00]})
          raise SafetyError, "Unsafe name in serial directory response"
        end

        name
      end

      def copy_file(output, remote, relative, capabilities)
        attempts = 0
        begin
          attempts += 1
          records = request(expected: "READCAP") { |marker| SerialTemplates.read_capability(remote, marker) }
          cap = records.find { |record| record[0] == "READCAP" }
          unless records.size == 1 && cap&.size == 2 && %w[read getc].include?(cap[1])
            raise FormatError, "No supported file reader"
          end

          records = request(expected: "DATA") do |marker|
            SerialTemplates.transfer(remote, capabilities, cap[1], marker)
          end
          data = decode_transfer(records)
          output.write(path: relative, data: data, original_name: File.basename(relative))
        rescue Error, IOError, SystemCallError => e
          retry if attempts < 3

          output.warning("TRANSFER_FAILED", "#{remote}: #{e.message}")
          output.write(path: relative, data: "".b, status: "transfer_error", error: e.message)
        end
      end
    end
  end
end
