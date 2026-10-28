# frozen_string_literal: true

require "time"

module Sandcrawler
  class Manifest
    attr_reader :data

    def initialize(source:, volume: nil)
      @data = { tool: "sandcrawler", tool_version: VERSION, created_at: Time.now.iso8601,
                source: source, volume: volume, files: [], directories: [], warnings: [] }
    end

    def self.json_safe(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key] = json_safe(item)
          next unless item.is_a?(String) && item.b != result[key].b

          hex_key = key.is_a?(Symbol) ? :"#{key}_hex" : "#{key}_hex"
          result[hex_key] = item.b.unpack1("H*")
        end
      when Array then value.map { |item| json_safe(item) }
      when String then value.dup.force_encoding(Encoding::UTF_8).scrub
      else value
      end
    end

    def warning(code, detail)
      item = { code: code.to_s.dup.force_encoding(Encoding::UTF_8).scrub,
               detail: detail.to_s.dup.force_encoding(Encoding::UTF_8).scrub }
      @data[:warnings] << item unless @data[:warnings].include?(item)
      item
    end
  end
end
