# frozen_string_literal: true

require_relative "../fat/volume"

module Sandcrawler
  module Recovery
    class Carver
      def initialize(source, block_size: 4096, offset: 0, length: nil)
        @source = source
        @block_size = block_size
        @offset = offset
        @length = length || (source.size - offset)
        unless block_size.is_a?(Integer) && block_size.positive? &&
               offset >= 0 && @length >= 0 && offset + @length <= source.size
          raise UsageError, "Invalid carving range or block size"
        end
      end

      def classify(bytes)
        return "zero" if bytes.empty? || bytes.bytes.all?(&:zero?)
        return "erased" if bytes.bytes.all? { |byte| byte == 255 }

        text = bytes.dup.force_encoding("UTF-8")
        return "binary" unless text.valid_encoding?

        printable = text.each_char.count { |char| char.match?(/[[:print:]\t\r\n]/) }
        printable.to_f / text.length >= 0.95 ? "text" : "binary"
      end

      def each
        return enum_for(__method__) unless block_given?

        data = "".b
        start = nil
        (@offset...(@offset + @length)).step(@block_size) do |offset|
          length = [@block_size, @offset + @length - offset].min
          begin
            bytes = @source.read_at(offset, length)
          rescue Error, IOError, SystemCallError => e
            yield fragment(start, data) if start
            yield unreadable_fragment(offset, length, e)
            start = nil
            data = "".b
            next
          end
          if classify(bytes) == "text"
            start ||= offset
            data << bytes
          elsif start
            yield fragment(start, data)
            start = nil
            data = "".b
          end
        end
        yield fragment(start, data) if start
      end

      private

      def unreadable_fragment(offset, length, error)
        entry = FAT::DirEntry.recovered(path: format("%08x.txt", offset), size: length)
        warnings = [{ code: "READ_ERROR", detail: "Source offset #{offset}, length #{length}: #{error.message}" }]
        result = FAT::Volume::ReadResult.new(data: "".b, status: "read_error", warnings: warnings)
        [entry, result]
      end

      def fragment(offset, data)
        entry = FAT::DirEntry.recovered(path: format("%08x.txt", offset), size: data.bytesize)
        warnings = [{ code: "CARVED_TEXT",
                      detail: "Text fragment at source offset #{offset}; original boundaries are unknown" }]
        result = FAT::Volume::ReadResult.new(data: data, status: "carved", warnings: warnings)
        [entry, result]
      end
    end
  end
end
