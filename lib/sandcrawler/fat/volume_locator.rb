# frozen_string_literal: true

require_relative "volume"

module Sandcrawler
  module FAT
    class VolumeLocator
      Candidate = Struct.new(:offset, :boot_sector, :score, :score_details, :boot_sector_offset, keyword_init: true) do
        def to_h
          boot_sector.to_h.merge(offset: offset, size: boot_sector.byte_size, score: score,
                                 score_details: score_details, boot_sector_offset: boot_sector_offset || offset,
                                 warnings: warnings)
        end

        def warnings
          return [] unless boot_sector_offset && boot_sector_offset != offset

          [{ code: "BACKUP_BOOT_SECTOR",
             detail: "Boot sector at #{boot_sector_offset} implies volume at #{offset}; " \
                     "FAT copies match and the root entry is plausible" }]
        end
      end

      def initialize(source)
        @source = source
      end

      def candidates
        @candidates ||= begin
          found = {}
          (0..(@source.size - 512)).step(512) do |offset|
            bytes = @source.read_at(offset, 512)
            candidate = inspect_boot(offset, bytes)
            backup = inspect_backup(offset, bytes, candidate)
            if backup
              found[backup.offset] ||= backup
            elsif candidate
              found[offset] = candidate
            end
            next if candidate || backup || bytes.byteslice(510, 2) != "\x55\xAA".b

            mbr_offsets(bytes).each do |partition_offset|
              next if found.key?(partition_offset) || partition_offset + 512 > @source.size

              candidate = inspect_boot(partition_offset, @source.read_at(partition_offset, 512))
              found[partition_offset] = candidate if candidate
            end
          end
          found.values.sort_by { |candidate| [-candidate.score, candidate.offset] }
        end
      end

      private

      def inspect_backup(offset, bytes, candidate)
        return if candidate&.score_details&.key?(:media)

        boot = candidate&.boot_sector || BootSector.new(bytes)
        return unless boot.fat_type == "FAT32" && boot.backup_sector.between?(1, boot.reserved_sectors - 1)

        base = offset - (boot.backup_sector * boot.bytes_per_sector)
        return if base.negative?

        recovered = inspect_boot(base, bytes)
        return unless recovered && %i[media fat_copies root_entry].all? { |key| recovered.score_details.key?(key) }

        recovered.boot_sector_offset = offset
        recovered
      rescue FormatError, OutOfRangeError
        nil
      end

      def inspect_boot(offset, bytes)
        boot = BootSector.new(bytes, available_size: @source.size - offset)
        details = {}
        fat_offset = offset + (boot.reserved_sectors * boot.bytes_per_sector)
        details[:media] = 2 if @source.read_at(fat_offset, 1).getbyte(0) == boot.media
        if boot.fat_count == 2
          size = boot.fat_sectors * boot.bytes_per_sector
          details[:fat_copies] = 2 if @source.read_at(fat_offset, size) == @source.read_at(fat_offset + size, size)
        end
        root = if boot.root_cluster
                 offset + boot.cluster_offset(boot.root_cluster)
               else
                 offset + ((boot.reserved_sectors + (boot.fat_count * boot.fat_sectors)) * boot.bytes_per_sector)
               end
        entry = @source.read_at(root, 32)
        if entry.getbyte(0).positive? && entry.getbyte(0) != 255 && (entry.getbyte(11) & 0xC0).zero?
          details[:root_entry] = 2
        end
        details[:r2p2_label] = 3 if boot.label.include?("R2P2")
        Candidate.new(offset: offset, boot_sector: boot, score: details.values.sum, score_details: details)
      rescue FormatError, OutOfRangeError
        nil
      end

      def mbr_offsets(bytes)
        4.times.flat_map do |index|
          entry = bytes.byteslice(446 + (index * 16), 16)
          next [] unless [0x01, 0x04, 0x06, 0x0B, 0x0C, 0x0E].include?(entry.getbyte(4))

          start = entry.byteslice(8, 4).unpack1("V")
          start.positive? ? [start * 512, start * 4096] : []
        end
      end
    end
  end
end
