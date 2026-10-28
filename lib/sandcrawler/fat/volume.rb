# frozen_string_literal: true

require "set"
require_relative "../image/slice"
require_relative "boot_sector"
require_relative "allocation_table"
require_relative "dir_entry"
require_relative "lfn_assembler"

module Sandcrawler
  module FAT
    class Volume
      ReadResult = Struct.new(:data, :status, :warnings, keyword_init: true)
      attr_reader :boot_sector, :allocation_table, :warnings, :referenced_clusters, :source, :offset

      def initialize(source, offset: 0, boot_sector: nil, fat: nil, codepage: "IBM437")
        unless offset.is_a?(Integer) && offset >= 0 && offset < source.size
          raise OutOfRangeError,
                "Volume offset outside source"
        end

        Encoding.find(codepage)
        @offset = offset
        @boot_sector = boot_sector || BootSector.new(source.read_at(offset, 512), available_size: source.size - offset)
        @source = Image::Slice.new(source, offset, @boot_sector.byte_size)
        @allocation_table = AllocationTable.new(@source, @boot_sector, fat: fat)
        @warnings = @allocation_table.warnings.dup
        @referenced_clusters = Set.new
        @cluster_owners = {}
        @crosslinked_clusters = Set.new
        @ambiguous_paths = Set.new
        @indexed = false
        @codepage = codepage
      end

      def metadata
        boot_sector.to_h.merge(offset: offset, fat_selection: allocation_table.selection,
                               fat_copies_consistent: allocation_table.copies_consistent)
      end

      def each_entry(recursive: true, deleted: false)
        return enum_for(__method__, recursive: recursive, deleted: deleted) unless block_given?

        pending = [["", boot_sector.root_cluster]]
        seen_directories = Set.new
        seen_paths = Set.new
        until pending.empty?
          path, cluster = pending.shift
          if cluster && seen_directories.include?(cluster)
            warn_once("DIRECTORY_LOOP", "Directory cluster #{cluster} is already visited")
            next
          end
          seen_directories << cluster if cluster
          directory_data(cluster, path).then do |data|
            parse_entries(data, path, deleted: deleted).each do |entry|
              unless entry.deleted?
                if seen_paths.include?(entry.path)
                  @ambiguous_paths << entry.path
                  warn_once("DUPLICATE_ENTRY", "Multiple live directory entries use #{entry.path}")
                end
                seen_paths << entry.path
                track_entry(entry)
                pending << [entry.path, entry.first_cluster] if entry.directory? && recursive
              end
              yield entry
            end
          end
        end
        @indexed = true if recursive && !deleted
      end

      def read(entry)
        each_entry.to_a unless @indexed
        warnings = []
        if @ambiguous_paths.include?(entry.path)
          warnings << { code: "DUPLICATE_ENTRY", detail: "Multiple live directory entries use #{entry.path}" }
        end
        if entry.size.zero?
          return ReadResult.new(data: "".b, status: warnings.empty? ? "ok" : "chain_error", warnings: warnings)
        end

        limit = (entry.size + boot_sector.cluster_size - 1) / boot_sector.cluster_size
        chain = allocation_table.chain(entry.first_cluster, limit: limit)
        data = "".b
        warnings += chain.warnings
        erased = false
        chain.clusters.each do |cluster|
          bytes = read_cluster(cluster)
          erased ||= bytes.bytes.all? { |byte| byte == 255 }
          data << bytes
        end
        status = @ambiguous_paths.include?(entry.path) ? "chain_error" : chain.status
        if chain.clusters.any? { |cluster| @crosslinked_clusters.include?(cluster) }
          status = "chain_error"
          warnings << { code: "CROSS_LINK", detail: "#{entry.path} shares clusters with another directory entry" }
        end
        status = "truncated" if status == "ok" && data.bytesize < entry.size
        if erased
          warnings << { code: "ERASED_CLUSTER", detail: "#{entry.path} contains an erased cluster" }
          status = "suspect_erased" if status == "ok"
        end
        ReadResult.new(data: data.byteslice(0, entry.size), status: status, warnings: warnings)
      rescue Error, IOError, SystemCallError => e
        ReadResult.new(data: data || "".b, status: "chain_error",
                       warnings: (warnings || []) + [{ code: "READ_ERROR", detail: e.message }])
      end

      def read_cluster(cluster)
        source.read_at(boot_sector.cluster_offset(cluster), boot_sector.cluster_size)
      end

      private

      def directory_data(cluster, path)
        unless cluster
          position = (boot_sector.reserved_sectors + (boot_sector.fat_count * boot_sector.fat_sectors)) *
                     boot_sector.bytes_per_sector
          return source.read_at(position, boot_sector.root_entry_count * 32)
        end

        chain = allocation_table.chain(cluster)
        track_clusters(chain.clusters, path)
        chain.warnings.each { |warning| warn_once(warning[:code], warning[:detail]) }
        data = "".b
        chain.clusters.each { |number| data << read_cluster(number) }
        data
      rescue Error, IOError, SystemCallError => e
        warn_once("DIRECTORY_ERROR", e.message)
        data || "".b
      end

      def parse_entries(data, parent, deleted:)
        entries = []
        lfn = LfnAssembler.new
        past_end = false
        (0...data.bytesize).step(32) do |position|
          bytes = data.byteslice(position, 32)
          break if bytes.bytesize < 32

          if bytes.getbyte(0).zero?
            past_end = true
            lfn.clear
            break unless deleted

            next
          end
          if past_end && bytes.getbyte(0) != 0xE5
            lfn.clear
            next
          end
          if bytes.bytes.all? { |byte| byte == 255 } || (bytes.getbyte(11) & 0xC0).positive?
            warn_once("DIRECTORY_DAMAGED", "Invalid directory entry in #{parent.empty? ? '/' : parent}")
            lfn.clear
            next
          end
          if bytes.getbyte(11) == 0x0F
            lfn.add(bytes)
            next
          end
          name = lfn.take(bytes)
          next if (bytes.getbyte(11) & 0x08).positive? || (bytes.getbyte(0) == 0xE5 && !deleted)
          next if [".          ", "..         "].include?(bytes.byteslice(0, 11))

          entry = DirEntry.new(bytes, fat_type: boot_sector.fat_type, codepage: @codepage, name: name, parent: parent)
          next if [".", "..", ""].include?(entry.name)

          entries << entry
        end
        entries
      end

      def track_entry(entry)
        return if entry.first_cluster < 2
        return if entry.size.zero? && !entry.directory?

        limit = entry.directory? ? nil : (entry.size + boot_sector.cluster_size - 1) / boot_sector.cluster_size
        track_clusters(allocation_table.chain(entry.first_cluster, limit: limit).clusters, entry.path)
      end

      def track_clusters(clusters, owner)
        @referenced_clusters.merge(clusters)
        clusters.each do |cluster|
          if @cluster_owners.key?(cluster) && @cluster_owners[cluster] != owner
            @crosslinked_clusters << cluster
            warn_once("CROSS_LINK", "Cluster #{cluster} is shared by #{@cluster_owners[cluster]} and #{owner}")
          else
            @cluster_owners[cluster] = owner
          end
        end
      end

      def warn_once(code, detail)
        warning = { code: code, detail: detail }
        warnings << warning unless warnings.include?(warning)
      end
    end
  end
end
