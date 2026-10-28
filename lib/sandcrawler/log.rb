# frozen_string_literal: true

module Sandcrawler
  class Log
    attr_reader :lines

    def self.escape(message)
      message.to_s.b.force_encoding(Encoding::UTF_8).scrub.gsub(/[\u0000-\u001f\u007f-\u009f]/) do |character|
        format("\\u%04x", character.ord)
      end
    end

    def initialize(io: $stderr, verbose: false, quiet: false)
      @io = io
      @verbose = verbose
      @quiet = quiet
      @lines = []
    end

    def info(message)
      record("INFO", message, !@quiet)
    end

    def warn(message)
      record("WARN", message, true)
    end

    def error(message)
      record("ERROR", message, true)
    end

    def debug(message)
      record("DEBUG", message, @verbose && !@quiet)
    end

    private

    def record(level, message, display)
      line = "#{level}: #{self.class.escape(message)}"
      @lines << line
      @io.puts(line) if display
    end
  end
end
