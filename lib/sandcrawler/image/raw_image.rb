# frozen_string_literal: true

require_relative "source"

module Sandcrawler
  module Image
    class RawImage < Source
      def initialize(path)
        @io = File.open(path, "rb")
        @size = @io.size
        @lock = Mutex.new
      end

      def read_at(offset, length)
        check_range(offset, length)
        return "".b if length.zero?

        data = begin
          @io.pread(length, offset)
        rescue NoMethodError, NotImplementedError, Errno::ENOSYS
          @lock.synchronize do
            @io.seek(offset)
            @io.read(length)
          end
        end
        raise OutOfRangeError, "Image changed or ended during read" unless data&.bytesize == length

        data.b
      rescue EOFError
        raise OutOfRangeError, "Image ended during read"
      end

      def close
        @io.close unless @io.closed?
      end
    end
  end
end
