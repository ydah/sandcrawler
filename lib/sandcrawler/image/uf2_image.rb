# frozen_string_literal: true

require_relative "source"

module Sandcrawler
  module Image
    class Uf2Image < Source
      FLASH_BASE = 0x10000000
      FLASH_SIZE = 16 * 1024 * 1024
      attr_reader :warnings

      def initialize(path)
        @blocks = []
        @warnings = []
        @numbers = {}
        File.open(path, "rb") do |io|
          raise FormatError, "UF2 size must be a multiple of 512" unless io.size.positive? && (io.size % 512).zero?

          parse_block(io.read(512)) until io.eof?
        end
        raise FormatError, "UF2 has no flash payload" if @blocks.empty?

        @blocks.sort_by!(&:first)
        @blocks.each_cons(2) do |left, right|
          overlap = left[0] + left[1].bytesize - right[0]
          next unless overlap.positive?
          raise FormatError, "Overlapping UF2 flash payloads" unless left == right
        end
        @blocks.uniq!
        if @numbers.size < @total
          @warnings << { code: "UF2_INCOMPLETE", detail: "UF2 contains #{@numbers.size} of #{@total} declared blocks" }
        end
        @size = @blocks.map { |offset, bytes| offset + bytes.bytesize }.max
        return unless @blocks.sum { |_, bytes| bytes.bytesize } != size

        @warnings << { code: "UF2_GAPS",
                       detail: "Missing UF2 ranges are filled with 0xFF; they are not verified erased flash" }
      end

      def read_at(offset, length)
        check_range(offset, length)
        result = "\xFF".b * length
        index = @blocks.bsearch_index { |start, bytes| start + bytes.bytesize > offset } || @blocks.length
        while index < @blocks.length
          start, bytes = @blocks[index]
          break if start >= offset + length

          first = [start, offset].max
          last = [start + bytes.bytesize, offset + length].min
          result[first - offset, last - first] = bytes.byteslice(first - start, last - first) if last > first
          index += 1
        end
        result
      end

      private

      def parse_block(block)
        raise FormatError, "UF2 block was truncated during read" unless block&.bytesize == 512

        magic1, magic2, flags, address, length, number, total = block.unpack("V7")
        unless magic1 == 0x0A324655 && magic2 == 0x9E5D5157 && block[508, 4].unpack1("V") == 0x0AB16F30
          raise FormatError, "Invalid UF2 magic"
        end
        raise FormatError, "UF2 file containers are unsupported" unless (flags & 0x1000).zero?
        unless length.between?(1, 476) && total.positive? && number < total
          raise FormatError, "Invalid UF2 payload or block number"
        end
        raise FormatError, "Inconsistent UF2 block count" if @total && total != @total
        raise FormatError, "Conflicting UF2 block number #{number}" if @numbers[number] && @numbers[number] != block

        @total = total
        @numbers[number] = block
        return unless (flags & 1).zero?

        offset = address - FLASH_BASE
        raise FormatError, "UF2 payload outside Pico XIP flash" unless offset >= 0 && offset + length <= FLASH_SIZE

        @blocks << [offset, block.byteslice(32, length)]
      end
    end
  end
end
