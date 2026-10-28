# frozen_string_literal: true

module Sandcrawler
  module FAT
    class LfnAssembler
      def initialize
        @entries = []
      end

      def add(bytes)
        @entries.clear if bytes.getbyte(0) != 0xE5 && (bytes.getbyte(0) & 0x40).positive?
        @entries << bytes
        @entries.clear if @entries.length > 20
      end

      def take(short)
        entries = @entries
        @entries = []
        return if entries.empty?

        deleted = short.getbyte(0) == 0xE5
        return unless valid_entries?(entries, short, deleted)

        units = entries.reverse.flat_map do |bytes|
          (bytes.byteslice(1, 10) + bytes.byteslice(14, 12) + bytes.byteslice(28, 4)).unpack("v*")
        end
        units = units.take_while { |unit| unit != 0 && unit != 0xFFFF }
        return if units.empty? || units.length > 255

        units.pack("v*").force_encoding("UTF-16LE").encode("UTF-8")
      rescue EncodingError
        nil
      end

      def clear
        @entries.clear
      end

      private

      def valid_entries?(entries, short, deleted)
        return false unless entries.all? { |entry| entry.getbyte(12).zero? && entry.byteslice(26, 2) == "\0\0" }

        if deleted
          entries.all? { |entry| entry.getbyte(0) == 0xE5 } && entries.map { |entry| entry.getbyte(13) }.uniq.size == 1
        else
          count = entries.first.getbyte(0) & 31
          return false unless entries.first.getbyte(0) == (count | 0x40) && count == entries.length

          checksum = short.byteslice(0, 11).bytes.reduce(0) { |sum, byte| (((sum & 1) << 7) + (sum >> 1) + byte) & 255 }
          entries.each_with_index.all? do |entry, index|
            expected = count - index
            expected |= 0x40 if index.zero?
            entry.getbyte(0) == expected && entry.getbyte(13) == checksum
          end
        end
      end
    end
  end
end
