# frozen_string_literal: true

require "set"

module Sandcrawler
  module FAT
    class AllocationTable
      Chain = Struct.new(:clusters, :status, :warnings, keyword_init: true)
      attr_reader :warnings, :selection, :copies_consistent

      def initialize(source, boot_sector, fat: nil)
        @boot = boot_sector
        @bits = @boot.fat_type.delete_prefix("FAT").to_i
        @warnings = []
        @erased_sectors = Set.new
        fat ||= @boot.active_fat
        raise UsageError, "FAT must be 1 or 2" if fat && ![1, 2].include?(fat)
        raise UsageError, "FAT#{fat} does not exist" if fat && fat > @boot.fat_count

        bytes = @boot.fat_sectors * @boot.bytes_per_sector
        first = source.read_at(@boot.reserved_sectors * @boot.bytes_per_sector, bytes)
        if @boot.fat_count == 2
          second = source.read_at((@boot.reserved_sectors + @boot.fat_sectors) * @boot.bytes_per_sector,
                                  bytes)
        end
        @copies_consistent = !second || first == second
        @selection = "fat#{fat || 1}"
        @data = first.dup
        selected = Set.new
        (0...bytes).step(@boot.bytes_per_sector) do |offset|
          a = first.byteslice(offset, @boot.bytes_per_sector)
          b = second&.byteslice(offset, @boot.bytes_per_sector)
          if b && a != b
            @warnings << { code: "FAT_MISMATCH",
                           detail: "FAT copies differ at sector #{offset / @boot.bytes_per_sector}" }
          end
          choice = fat || (b && erased?(a) && !erased?(b) ? 2 : 1)
          selected << choice
          sector = choice == 2 ? b : a
          if erased?(sector)
            @erased_sectors << (offset / @boot.bytes_per_sector)
            @warnings << { code: "FAT_ERASED",
                           detail: "Selected FAT sector #{offset / @boot.bytes_per_sector} is erased" }
          end
          @data[offset, sector.bytesize] = sector
        end
        @selection = selected.size == 1 ? "fat#{selected.first}" : "mixed"
      end

      def [](cluster)
        raise OutOfRangeError, "FAT index outside allocation table" unless cluster.between?(0, @boot.cluster_count + 1)

        if @bits == 12
          value = @data.byteslice(cluster + (cluster / 2), 2).unpack1("v")
          cluster.even? ? value & 0xFFF : value >> 4
        elsif @bits == 16
          @data.byteslice(cluster * 2, 2).unpack1("v")
        else
          @data.byteslice(cluster * 4, 4).unpack1("V") & 0x0FFFFFFF
        end
      end

      def eoc?(value)
        value >= { 12 => 0xFF8, 16 => 0xFFF8, 32 => 0x0FFFFFF8 }.fetch(@bits)
      end

      def allocated?(cluster)
        return false if erased_entry?(cluster)

        value = self[cluster]
        value.positive? && value != bad_marker && !reserved?(value)
      end

      def chain(first, limit: nil)
        clusters = []
        visited = Set.new
        warnings = []
        current = first
        status = "ok"
        loop do
          if !current.between?(2, @boot.cluster_count + 1) || visited.include?(current)
            status = "chain_error"
            warnings << { code: "CHAIN_ERROR", detail: "Invalid or repeated cluster #{current}" }
            break
          end
          visited << current
          clusters << current
          if erased_entry?(current)
            status = "chain_error"
            warnings << { code: "FAT_ERASED_ENTRY", detail: "Allocation metadata for cluster #{current} is erased" }
            break
          end
          following = self[current]
          break if eoc?(following)

          if following.zero?
            status = "truncated"
            warnings << { code: "CHAIN_FREE", detail: "Cluster #{current} points to free space" }
            break
          end
          if following == bad_marker || reserved?(following)
            status = "chain_error"
            warnings << { code: "CHAIN_ERROR", detail: "Bad or reserved link at cluster #{current}" }
            break
          end
          if limit && clusters.length >= limit
            status = "chain_error"
            warnings << { code: "CHAIN_TOO_LONG",
                          detail: "Chain continues beyond declared file size at cluster #{current}" }
            break
          end
          current = following
        end
        Chain.new(clusters: clusters, status: status, warnings: warnings)
      end

      private

      def erased_entry?(cluster)
        offset = @bits == 12 ? cluster + (cluster / 2) : cluster * (@bits / 8)
        length = @bits == 32 ? 4 : 2
        @erased_sectors.include?(offset / @boot.bytes_per_sector) ||
          @erased_sectors.include?((offset + length - 1) / @boot.bytes_per_sector)
      end

      def bad_marker
        { 12 => 0xFF7, 16 => 0xFFF7, 32 => 0x0FFFFFF7 }.fetch(@bits)
      end

      def reserved?(value)
        value == 1 || value.between?(bad_marker - 7, bad_marker - 1)
      end

      def erased?(sector)
        sector.bytes.all? { |byte| byte == 255 }
      end
    end
  end
end
