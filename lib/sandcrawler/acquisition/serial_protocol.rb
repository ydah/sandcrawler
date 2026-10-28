# frozen_string_literal: true

require "securerandom"
require "io/wait"

module Sandcrawler
  module Acquisition
    module SerialProtocol
      MARKER = "@@SANDCRAWLER|"
      ANSI = %r{\e\[[0-?]*[ -/]*[@-~]}
      MAX_RESPONSE_BYTES = 40 * 1024 * 1024
      MAX_RESPONSE_RECORDS = 65_537

      private

      def decode_transfer(records)
        data = +"".b
        sequence = 0
        ended = false
        records.each do |record|
          kind, first, second = record
          unless record.size == 3 && %w[DATA END].include?(kind)
            raise IntegrityError, "Unexpected serial transfer record"
          end

          if kind == "DATA"
            unless !ended && first == sequence.to_s && second&.match?(/\A(?:[0-9a-f]{2}){1,256}\z/i)
              raise IntegrityError, "Missing, duplicate or invalid serial chunk"
            end

            data << [second].pack("H*")
            sequence += 1
          elsif kind == "END"
            unless !ended && first == data.bytesize.to_s && second == (data.bytes.sum % 65_536).to_s
              raise IntegrityError, "Serial byte count or checksum mismatch"
            end

            ended = true
          end
        end
        raise IntegrityError, "Serial END marker missing" unless ended

        data
      end

      def decode_listing(records)
        ending = records.last
        entries = records[0...-1]
        unless ending&.size == 3 && ending[0] == "LISTEND" && ending[1] == entries.size.to_s &&
               entries.all? { |record| record.size == 3 && record[0] == "LIST" }
          raise IntegrityError, "Serial directory count or terminator mismatch"
        end

        checksum = entries.sum { |record| record.drop(1).join("|").bytes.sum } % 65_536
        raise IntegrityError, "Serial directory checksum mismatch" unless ending[2] == checksum.to_s

        names = entries.map { |record| record[2] }
        raise IntegrityError, "Duplicate serial directory entry" unless names.uniq.size == names.size

        entries
      end

      def request(expected:)
        marker = "#{MARKER}#{SecureRandom.hex(8)}|"
        code = yield marker
        error_marker = SerialTemplates.literal("#{marker}ERROR|")
        done_marker = SerialTemplates.literal("#{marker}DONE")
        @io.write("begin;#{code};rescue=>e;puts #{error_marker}+e.to_s;end;puts #{done_marker}\n")
        records = []
        response_bytes = 0
        deadline = monotonic + @timeout
        absolute_deadline = monotonic + 3600
        loop do
          line = read_line([deadline, absolute_deadline].min).gsub(ANSI, "").strip
          next unless line.start_with?(marker)

          record = line.delete_prefix(marker).split("|", -1)
          break if record == ["DONE"]

          allowed = [expected, "ERROR", { "DATA" => "END", "LIST" => "LISTEND" }[expected]]
          raise IntegrityError, "Unexpected serial response record" unless allowed.include?(record[0])

          response_bytes += line.bytesize
          if response_bytes > MAX_RESPONSE_BYTES || records.size >= MAX_RESPONSE_RECORDS
            raise IntegrityError, "Serial response exceeds the Pico transfer budget"
          end

          records << record
          deadline = monotonic + @timeout
        end
        error = records.find { |record| record[0] == "ERROR" }
        raise Error, "R2P2: #{error.drop(1).join('|')}" if error

        records
      end

      def wait_prompt
        deadline = monotonic + @timeout
        loop do
          if @buffer.gsub(ANSI, "").match?(/[>$#] ?\z/)
            @buffer.clear
            return
          end
          read_more(deadline)
        end
      end

      def read_line(deadline)
        loop do
          index = @buffer.index("\n")
          return @buffer.slice!(0, index + 1) if index

          read_more(deadline)
        end
      end

      def read_more(deadline)
        remaining = deadline - monotonic
        unless remaining.positive? && @io.to_io.wait_readable(remaining)
          raise IntegrityError, "Serial response timed out"
        end

        chunk = @io.read_nonblock(4096, exception: false)
        raise IOError, "Serial connection closed" if chunk.nil?
        return if chunk == :wait_readable

        @buffer << chunk
        raise FormatError, "Serial line exceeds 1 MiB" if @buffer.bytesize > 1_048_576
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
