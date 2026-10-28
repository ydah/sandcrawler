# frozen_string_literal: true

require_relative "source"

module Sandcrawler
  module Image
    class Slice < Source
      def initialize(source, offset, length)
        unless offset.is_a?(Integer) && length.is_a?(Integer) &&
               offset >= 0 && length >= 0 && offset + length <= source.size
          raise OutOfRangeError, "Slice outside image"
        end

        @source = source
        @offset = offset
        @size = length
      end

      def read_at(offset, length)
        check_range(offset, length)
        @source.read_at(@offset + offset, length)
      end
    end
  end
end
