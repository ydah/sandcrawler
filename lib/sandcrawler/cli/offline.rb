# frozen_string_literal: true

module Sandcrawler
  class CLI
    module Offline
      private

      def run_scan(args)
        image = Image.open(args.first)
        candidates = locate(image)
        emit(candidates.map(&:to_h)) do
          candidates.each do |candidate|
            line = format("0x%<offset>08X  score=%<score>s  %<geometry>s",
                          offset: candidate.offset, score: candidate.score, geometry: candidate.boot_sector.to_h)
            @stdout.puts(line)
          end
        end
        0
      ensure
        image&.close
      end

      def run_ls(args)
        image = Image.open(args.first)
        volume = open_volume(image)
        entries = volume.each_entry(deleted: @options[:deleted]).to_a
        emit(entries.map(&:to_h)) do
          entries.each do |entry|
            prefix = @options[:long] ? "#{entry.size.to_s.rjust(10)} #{entry.mtime&.iso8601 || '-'} " : ""
            name = Log.escape(entry.path)
            @stdout.puts("#{prefix}#{'[deleted] ' if entry.deleted?}#{name}#{'/' if entry.directory?}")
          end
        end
        volume.warnings.each { |warning| @log.warn(warning.to_s) }
        volume.warnings.empty? ? 0 : 4
      ensure
        image&.close
      end

      def run_extract(args)
        path = args.first
        protect_input(path)
        protect_input(@options[:reference]) if @options[:reference]
        image = Image.open(path)
        source = { type: "image", path: File.expand_path(path), sha256: Digest::SHA256.file(path).hexdigest,
                   size: File.size(path), image_size: image.size }
        if @options[:reference]
          source[:reference_image] = { path: File.expand_path(@options[:reference]),
                                       sha256: Digest::SHA256.file(@options[:reference]).hexdigest }
        end
        volume = volume_for_extraction(image)
        output = Extractor.new(@options[:out], source: source, volume: volume&.metadata,
                                               force: @options[:force], log: @log)
        if @options[:reference]
          output.warning("REFERENCE_GEOMETRY",
                         "Geometry borrowed from #{@options[:reference]}; verify firmware and board match")
        end
        output.warning("MANUAL_GEOMETRY", @options[:geometry].inspect) if @options[:geometry]
        Array(image.respond_to?(:warnings) ? image.warnings : []).each { |w| record_warning(output, w) }
        if volume
          extract_volume(volume, output)
        else
          output.warning("NO_FAT_VOLUME", "No usable FAT boot sector; carving the image without filesystem metadata")
        end
        carve(image, volume, output) if @options[:carve]
        verify_source(source, output)
        verify_source(source[:reference_image], output) if source[:reference_image]
        manifest = output.finish
        emit(manifest) { @stdout.puts("Recovered #{manifest[:files].size} files to #{output.out}") }
        volume ? result_code(manifest) : 4
      rescue Error, IOError, SystemCallError => e
        if output
          output.warning("EXTRACTION_FAILED", e.message)
          output.finish
        end
        raise
      ensure
        image&.close
      end

      def verify_source(source, output)
        return if Digest::SHA256.file(source[:path]).hexdigest == source[:sha256]

        output.warning("SOURCE_CHANGED", "Source changed during recovery: #{source[:path]}")
        raise IntegrityError, "Source changed during recovery; saved results need a fresh acquisition"
      rescue IOError, SystemCallError => e
        output.warning("SOURCE_CHANGED", "Cannot verify source after recovery: #{e.message}")
        raise IntegrityError, "Source could not be verified after recovery"
      end

      def volume_for_extraction(image)
        open_volume(image)
      rescue FormatError
        raise unless @options[:carve] && !@options[:geometry] && !@options[:reference] && !@options[:offset]

        nil
      end

      def extract_volume(volume, output)
        volume.each_entry do |entry|
          if entry.directory?
            output.directory(path: entry.path, mtime: entry.mtime, attributes: entry.attributes,
                             first_cluster: entry.first_cluster)
          else
            write_result(output, entry, volume.read(entry), "files")
          end
        end
        if @options[:deleted]
          Recovery::Undelete.new(volume).each { |entry, result| write_result(output, entry, result, "deleted") }
        end
        if @options[:orphans]
          Recovery::Orphans.new(volume).each { |entry, result| write_result(output, entry, result, "lost+found") }
        end
        volume.warnings.each { |warning| record_warning(output, warning) }
      end

      def write_result(output, entry, result, category)
        output.write(path: entry.path, original_name: entry.name, data: result.data, category: category,
                     status: result.status, mtime: entry.mtime, attributes: entry.attributes,
                     first_cluster: entry.first_cluster, expected_size: entry.size, warnings: result.warnings)
        result.warnings.each { |warning| record_warning(output, warning) }
      end

      def record_warning(output, warning)
        if warning.is_a?(Hash)
          output.warning(warning[:code] || warning["code"], warning[:detail] || warning["detail"])
        else
          output.warning("RECOVERY_WARNING", warning.to_s)
        end
      end

      def carve(image, volume, output)
        boot = volume&.boot_sector
        options = if boot
                    { offset: volume.offset + (boot.first_data_sector * boot.bytes_per_sector),
                      block_size: boot.cluster_size, length: boot.cluster_count * boot.cluster_size }
                  else
                    {}
                  end
        Recovery::Carver.new(image, **options).each { |entry, result| write_result(output, entry, result, "carved") }
      end

      def open_volume(image)
        candidate = locate(image).first
        raise FormatError, "No FAT volume found; try --reference-image, --geometry, or extract --carve" unless candidate

        volume = FAT::Volume.new(image, offset: candidate.offset, boot_sector: candidate.boot_sector,
                                        fat: @options[:fat], codepage: @options[:codepage])
        volume.warnings.concat(candidate.warnings) if candidate.respond_to?(:warnings)
        volume
      end

      def locate(image)
        if @options[:geometry]
          offset = @options[:offset] || @options[:geometry][:offset] || 0
          begin
            boot = FAT::BootSector.from_geometry(@options[:geometry], available_size: image.size - offset)
          rescue FormatError => e
            raise UsageError, e.message
          end
          return [manual_candidate(offset, boot)]
        end
        source = @options[:reference] ? Image.open(@options[:reference]) : image
        if @options.key?(:offset)
          offset = @options[:offset]
          boot = FAT::BootSector.new(source.read_at(offset, 512), available_size: image.size - offset)
          return [manual_candidate(offset, boot)]
        end
        candidates = FAT::VolumeLocator.new(source).candidates
        candidates.each { |candidate| @log.debug(candidate.to_h.inspect) }
        candidates
      ensure
        source&.close if source && source != image
      end

      def manual_candidate(offset, boot)
        Struct.new(:offset, :boot_sector, :score) do
          def to_h
            boot_sector.to_h.merge(offset: offset, score: score)
          end
        end.new(offset, boot, 0)
      end

      def protect_input(path)
        input = File.realpath(path)
        parent = File.expand_path(@options[:out])
        tail = []
        until File.exist?(parent) || File.symlink?(parent)
          tail.unshift(File.basename(parent))
          parent = File.dirname(parent)
        end
        destination = File.join(File.realpath(parent), *tail)
        return unless input == destination || input.start_with?(destination + File::SEPARATOR)

        raise SafetyError, "Output must not contain the source image: #{path}"
      end
    end
  end
end
