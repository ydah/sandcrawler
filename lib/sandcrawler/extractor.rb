# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "json"
require "digest"

module Sandcrawler
  class Extractor
    CATEGORIES = [nil, "files", "deleted", "lost+found", "carved"].freeze
    attr_reader :out, :manifest

    def initialize(out, source:, volume: nil, force: false, log: nil)
      @out = File.expand_path(out)
      raise SafetyError, "Output is a symlink: #{@out}" if File.symlink?(@out)
      if File.exist?(@out) && (!File.directory?(@out) || (!force && !Dir.empty?(@out)))
        raise SafetyError, "Output must be an empty directory (or use --force): #{@out}"
      end

      FileUtils.mkdir_p(@out)
      @out = File.realpath(@out)
      @manifest = Manifest.new(source: source, volume: volume)
      @paths = PathSanitizer.new
      @log = log || Log.new
      @directory_times = []
    end

    def write(path:, data:, category: "files", status: "ok", mtime: nil, original_name: nil, **metadata)
      validate_category(category)
      entry = metadata.merge(path: path, original_name: original_name || path.to_s.b.split("/").last,
                             status: status, mtime: mtime&.iso8601)
      %i[path original_name].each do |key|
        text = entry[key].to_s.dup.force_encoding(Encoding::UTF_8)
        entry[:"#{key}_hex"] = text.b.unpack1("H*") unless text.valid_encoding?
        entry[key] = text.scrub
      end
      relative = output_path(path, category, status)
      target = safe_target(relative)
      Tempfile.create([".sandcrawler-", ".tmp"], File.dirname(target), binmode: true) do |file|
        begin
          data.is_a?(String) ? file.write(data.b) : IO.copy_stream(data, file)
        rescue IOError, SystemCallError => e
          raise unless file.size.positive?

          warning("FILE_ERROR", "#{path}: #{e.message}; preserving readable prefix")
          entry[:status] = "read_error"
          relative = output_path(path, category, "read_error")
          target = safe_target(relative)
        end
        if entry[:status] == "ok" && entry[:expected_size] && file.size != entry[:expected_size]
          warning("SIZE_MISMATCH", "#{path}: expected #{entry[:expected_size]} bytes, recovered #{file.size}")
          entry[:status] = file.size < entry[:expected_size] ? "truncated" : "read_error"
          relative = output_path(path, category, entry[:status])
          target = safe_target(relative)
        end
        commit_file(file, target)
      end
      entry.merge!(output: relative, size: File.size(target), sha256: Digest::SHA256.file(target).hexdigest)
      restore_time(target, mtime) if mtime
      @manifest.data[:files] << entry
      entry
    rescue IOError, SystemCallError => e
      warning("FILE_ERROR", "#{path}: #{e.message}")
      entry ||= { path: path, original_name: original_name }
      entry.merge!(status: "read_error", output: nil, sha256: nil)
      @manifest.data[:files] << entry
      entry
    end

    def directory(path:, category: "files", mtime: nil, **metadata)
      validate_category(category)
      entry = metadata.merge(path: path, original_name: path.to_s.b.split("/").last,
                             mtime: mtime&.iso8601, status: "ok")
      relative = @paths.path(path, namespace: category, directory: true)
      target = safe_target("#{relative}/.directory-check")
      @directory_times << [File.dirname(target), mtime] if mtime
      @manifest.data[:directories] << entry.merge(output: relative)
      relative
    rescue IOError, SystemCallError => e
      warning("DIRECTORY_WRITE_ERROR", "#{path}: #{e.message}")
      @manifest.data[:directories] << entry.merge(status: "write_error", output: nil)
      nil
    end

    def warning(code, detail)
      @log.warn("#{code}: #{detail}")
      @manifest.warning(code, detail)
    end

    def finish
      @directory_times.reverse_each do |path, time|
        raise SafetyError, "Output became a symlink: #{path}" if File.symlink?(path)

        File.utime(time, time, path)
      rescue SystemCallError => e
        warning("TIMESTAMP_ERROR", e.message)
      end
      result = Manifest.json_safe(@manifest.data)
      @log.info("Manifest: files=#{result[:files].size}, directories=#{result[:directories].size}, " \
                "warnings=#{result[:warnings].size}")
      atomic_write(safe_target("manifest.json")) { |file| file.write("#{JSON.pretty_generate(result)}\n") }
      atomic_write(safe_target("sandcrawler.log")) { |file| file.write("#{@log.lines.join("\n")}\n") }
      result
    end

    private

    def validate_category(category)
      raise UsageError, "Unknown output category: #{category}" unless CATEGORIES.include?(category)
    end

    def output_path(path, category, status)
      suffix = %w[truncated chain_error partial read_error transfer_error].include?(status) ? ".partial" : ""
      @paths.path("#{path}#{suffix}", namespace: category)
    end

    def restore_time(target, time)
      File.utime(time, time, target)
    rescue SystemCallError => e
      warning("TIMESTAMP_ERROR", e.message)
    end

    def safe_target(relative)
      raise SafetyError, "Output became a symlink: #{@out}" if File.symlink?(@out)

      current = @out
      components = relative.split("/")
      components.each_with_index do |component, index|
        current = File.join(current, component)
        raise SafetyError, "Refusing output symlink: #{current}" if File.symlink?(current)
        next if index == components.size - 1

        begin
          Dir.mkdir(current)
        rescue Errno::EEXIST
          raise SafetyError, "Refusing output symlink: #{current}" if File.symlink?(current)
        end
        raise SafetyError, "Not a directory: #{current}" unless File.directory?(current)
      end
      current
    end

    def atomic_write(target)
      Tempfile.create([".sandcrawler-", ".tmp"], File.dirname(target), binmode: true) do |file|
        yield file
        commit_file(file, target)
      end
    end

    def commit_file(file, target)
      file.flush
      file.close
      safe_target(target.delete_prefix(@out + File::SEPARATOR))
      File.rename(file.path, target)
    end
  end
end
