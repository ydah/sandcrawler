# frozen_string_literal: true

module Sandcrawler
  module Image
    def self.open(path)
      File.extname(path).downcase == ".uf2" ? Uf2Image.new(path) : RawImage.new(path)
    end

    class Source
      attr_reader :size

      def check_range(offset, length)
        unless offset.is_a?(Integer) && length.is_a?(Integer) && offset >= 0 && length >= 0 && offset + length <= size
          raise OutOfRangeError, "Read outside image: offset=#{offset}, length=#{length}, size=#{size}"
        end
      end

      def close; end

      def warnings
        []
      end
    end
  end
end
