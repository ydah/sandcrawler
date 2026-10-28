# frozen_string_literal: true

require "date"
require "time"

module Sandcrawler
  module FAT
    class DirEntry
      attr_accessor :path
      attr_reader :name, :size, :mtime, :attributes, :first_cluster

      def initialize(bytes, fat_type: "FAT12", codepage: "IBM437", name: nil, parent: "")
        raise FormatError, "Directory entry must contain 32 bytes" unless bytes.bytesize == 32

        @deleted = bytes.getbyte(0) == 0xE5
        @directory = (bytes.getbyte(11) & 0x10).positive?
        @attributes = { 1 => "readonly", 2 => "hidden", 4 => "system", 8 => "volume_label", 16 => "directory",
                        32 => "archive" }
                      .filter_map do |bit, label|
          label if (bytes.getbyte(11) & bit).positive?
        end
        @name = name || short_name(bytes, codepage)
        @path = parent.empty? ? @name : "#{parent}/#{@name}"
        @size = bytes.byteslice(28, 4).unpack1("V")
        @first_cluster = bytes.byteslice(26, 2).unpack1("v")
        @first_cluster |= (bytes.byteslice(20, 2).unpack1("v") & 0xFFF) << 16 if fat_type == "FAT32"
        @mtime = decode_time(bytes.byteslice(24, 2).unpack1("v"), bytes.byteslice(22, 2).unpack1("v"))
      end

      def self.recovered(path:, size:, first_cluster: nil)
        bytes = (" " * 11) + ("\0" * 21)
        bytes.setbyte(11, 0x20)
        bytes[28, 4] = [size].pack("V")
        bytes[26, 2] = [(first_cluster || 0) & 0xFFFF].pack("v")
        bytes[20, 2] = [(first_cluster || 0) >> 16].pack("v")
        new(bytes, fat_type: "FAT32", name: path.split("/").last).tap { |entry| entry.path = path }
      end

      def directory?
        @directory
      end

      def deleted?
        @deleted
      end

      def to_h
        { path: path, original_name: name, size: size, mtime: mtime&.iso8601,
          attributes: attributes, first_cluster: first_cluster, deleted: deleted?, directory: directory? }
      end

      private

      def short_name(bytes, codepage)
        short = bytes.byteslice(0, 11).dup
        short.setbyte(0, 0x5F) if deleted?
        short.setbyte(0, 0xE5) if short.getbyte(0) == 0x05
        base = short.byteslice(0, 8).rstrip.encode("UTF-8", codepage, invalid: :replace, undef: :replace)
        extension = short.byteslice(8, 3).rstrip.encode("UTF-8", codepage, invalid: :replace, undef: :replace)
        base = base.downcase if (bytes.getbyte(12) & 0x08).positive?
        extension = extension.downcase if (bytes.getbyte(12) & 0x10).positive?
        extension.empty? ? base : "#{base}.#{extension}"
      end

      def decode_time(date, time)
        year = 1980 + (date >> 9)
        month = (date >> 5) & 15
        day = date & 31
        hour = time >> 11
        minute = (time >> 5) & 63
        second = (time & 31) * 2
        return unless Date.valid_date?(year, month, day) && hour < 24 && minute < 60 && second < 60

        Time.local(year, month, day, hour, minute, second)
      rescue ArgumentError, RangeError
        nil
      end
    end
  end
end
