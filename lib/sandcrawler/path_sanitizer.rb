# frozen_string_literal: true

require "digest"

module Sandcrawler
  class PathSanitizer
    RESERVED = /\A(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|\z)/i

    def initialize
      @directories = {}
      @used = Hash.new { |hash, key| hash[key] = {} }
      %w[manifest.json sandcrawler.log].each { |name| @used[""][name] = true }
    end

    def self.component(name)
      text = name.to_s.b.force_encoding(Encoding::UTF_8).scrub("_")
      text = text.gsub(%r{[\x00-\x1f\x7f<>:"/\\|?*]}, "_").sub(/[. ]+\z/, "")
      text = "_" if text.empty? || %w[. ..].include?(text)
      text = "_#{text}" if RESERVED.match?(text)
      if text.bytesize > 180
        suffix = Digest::SHA256.hexdigest(text)[0, 12]
        text = text.byteslice(0, 160).scrub("") + "~#{suffix}"
      end
      text
    end

    def path(original, directory: false, namespace: nil)
      text = original.to_s.b
      parts = text.tr("\\", "/").sub(%r{\A[A-Za-z]:/}, "").split("/")
      parts.reject! { |part| part.empty? || %w[. ..].include?(part) }
      parts = ["_"] if parts.empty?
      parts.unshift(namespace) if namespace
      parent = ""
      parts.each_with_index do |part, index|
        is_directory = index < parts.size - 1 || directory
        key = [parent, part]
        name = is_directory && @directories[key]
        unless name
          name = available_name(parent, self.class.component(part))
          @directories[key] = name if is_directory
        end
        parent = parent.empty? ? name : "#{parent}/#{name}"
      end
      parent
    end

    private

    def available_name(parent, name)
      candidate = name
      number = 1
      while @used[parent][candidate.unicode_normalize(:nfc).downcase]
        number += 1
        extension = File.extname(name)
        candidate = "#{File.basename(name, extension)}~#{number}#{extension}"
      end
      @used[parent][candidate.unicode_normalize(:nfc).downcase] = true
      candidate
    end
  end
end
