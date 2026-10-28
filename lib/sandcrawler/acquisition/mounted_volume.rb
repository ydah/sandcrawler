# frozen_string_literal: true

module Sandcrawler
  module Acquisition
    class MountedVolume
      WARNING = "Mounted volumes may be changed by the OS. On Linux use mount -o ro; " \
                "on other systems prefer a BOOTSEL dump."

      def initialize(path)
        @path = File.realpath(path)
        raise UsageError, "Mount point is not a directory: #{path}" unless File.directory?(@path)
      end

      def copy(out, force: false, log: nil)
        reject_overlap!(out)
        output = Extractor.new(out, source: { type: "mounted_volume", path: @path }, force: force, log: log)
        output.warning("MOUNT_WRITE_RISK", WARNING)
        Dir.open(@path, &:read)
        Dir.glob("**/*", File::FNM_DOTMATCH, base: @path).sort.each do |relative|
          next if %w[. ..].include?(File.basename(relative))

          copy_entry(output, File.join(@path, relative))
        end
        output.finish
      rescue SystemCallError, IOError => e
        raise unless output

        output.warning("COPY_FAILED", "#{@path}: #{e.message}")
        output.finish
      end

      private

      def reject_overlap!(out)
        destination = File.expand_path(out)
        ancestor = destination
        ancestor = File.dirname(ancestor) until File.exist?(ancestor) || File.symlink?(ancestor)
        resolved = File.join(File.realpath(ancestor), destination.delete_prefix(ancestor).sub(%r{\A/}, ""))
        if resolved == @path || resolved.start_with?(@path + File::SEPARATOR) || @path.start_with?(resolved + File::SEPARATOR)
          raise SafetyError, "Source and output directories must not overlap"
        end
      end

      def copy_entry(output, path)
        relative = path.delete_prefix(@path + File::SEPARATOR)
        stat = File.lstat(path)
        if stat.symlink? || File.realpath(path) != path
          output.warning("SYMLINK_SKIPPED", relative)
        elsif stat.directory?
          Dir.open(path, &:read)
          output.directory(path: relative, mtime: stat.mtime)
        elsif stat.file?
          flags = File::RDONLY
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
          File.open(path, flags) do |file|
            opened = file.stat
            current = File.lstat(path)
            if File.realpath(path) != path || !opened.file? ||
               [current.dev, current.ino] != [stat.dev, stat.ino] || !File.identical?(file, path)
              raise IOError, "Source changed while opening #{relative}"
            end

            file.binmode
            record = output.write(path: relative, data: file, mtime: stat.mtime,
                                  original_name: File.basename(path), expected_size: stat.size)
            after = file.stat
            if [stat.size, stat.mtime, stat.ctime] != [after.size, after.mtime, after.ctime]
              record[:status] = "read_error" if record[:status] == "ok"
              output.warning("SOURCE_CHANGED", "#{relative} changed during copying; verify recovered bytes")
            end
          end
        else
          output.warning("SPECIAL_FILE_SKIPPED", relative)
        end
      rescue SystemCallError, IOError => e
        output.warning("COPY_FAILED", "#{relative}: #{e.message}")
        output.write(path: relative, data: "".b, status: "read_error", error: e.message)
      end
    end
  end
end
