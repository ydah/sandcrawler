# frozen_string_literal: true

module Sandcrawler
  module FAT
    class BootSector
      attr_reader :bytes_per_sector, :sectors_per_cluster, :reserved_sectors, :fat_count,
                  :root_entry_count, :total_sectors, :fat_sectors, :media, :root_cluster,
                  :root_dir_sectors, :first_data_sector, :cluster_count, :fat_type, :label, :active_fat, :backup_sector

      def initialize(bytes, available_size: nil)
        raise FormatError, "Boot sector is shorter than 512 bytes" if bytes.bytesize < 512
        unless (bytes.getbyte(0) == 0xEB && bytes.getbyte(2) == 0x90) || bytes.getbyte(0) == 0xE9
          raise FormatError, "Invalid FAT jump instruction"
        end
        raise FormatError, "Missing FAT signature" unless bytes.byteslice(510, 2) == "\x55\xAA".b

        @bytes_per_sector = bytes.byteslice(11, 2).unpack1("v")
        @sectors_per_cluster = bytes.getbyte(13)
        @reserved_sectors = bytes.byteslice(14, 2).unpack1("v")
        @fat_count = bytes.getbyte(16)
        @root_entry_count = bytes.byteslice(17, 2).unpack1("v")
        @total_sectors = bytes.byteslice(19, 2).unpack1("v")
        @total_sectors = bytes.byteslice(32, 4).unpack1("V") if @total_sectors.zero?
        @media = bytes.getbyte(21)
        @fat_sectors = bytes.byteslice(22, 2).unpack1("v")
        @fat_sectors = bytes.byteslice(36, 4).unpack1("V") if @fat_sectors.zero?
        validate_geometry(available_size)
        @root_dir_sectors = ((root_entry_count * 32) + bytes_per_sector - 1) / bytes_per_sector
        @first_data_sector = reserved_sectors + (fat_count * fat_sectors) + root_dir_sectors
        @cluster_count = (total_sectors - first_data_sector) / sectors_per_cluster
        raise FormatError, "FAT volume has no data clusters" unless cluster_count.positive?

        @fat_type = if cluster_count < 4085
                      "FAT12"
                    else
                      cluster_count < 65_525 ? "FAT16" : "FAT32"
                    end
        @root_cluster = fat_type == "FAT32" ? bytes.byteslice(44, 4).unpack1("V") & 0x0FFFFFFF : nil
        validate_fat(bytes)
        if fat_type == "FAT32"
          @backup_sector = bytes.byteslice(50, 2).unpack1("v")
          flags = bytes.byteslice(40, 2).unpack1("v")
          @active_fat = (flags & 15) + 1 unless (flags & 0x80).zero?
          raise FormatError, "Active FAT index exceeds FAT count" if active_fat && active_fat > fat_count
        end
        @label = bytes.byteslice(fat_type == "FAT32" ? 71 : 43, 11).delete("\0").strip.encode("UTF-8", "IBM437")
      end

      def self.from_geometry(values, available_size:)
        geometry = values.transform_keys(&:to_sym)
        bps, spc, reserved, fats, fatsz, root = %i[bps spc rsvd fats fatsz root].map do |key|
          Integer(geometry.fetch(key))
        end
        unless [512, 1024, 2048, 4096].include?(bps) && spc.between?(1, 128) &&
               reserved.between?(1, 65_535) && [1, 2].include?(fats) &&
               fatsz.between?(1, root.zero? ? 0xFFFFFFFF : 65_535) && root.between?(0, 65_535)
          raise FormatError, "Manual geometry contains out-of-range fields"
        end

        total = Integer(geometry.fetch(:total) { geometry.fetch(:totsec, available_size / bps) })
        raise FormatError, "Invalid total sector count" unless total.between?(1, 0xFFFFFFFF)

        media = Integer(geometry.fetch(:media, 0xF8))
        raise FormatError, "Invalid manual media byte" unless media.between?(0, 255)

        root_cluster = Integer(geometry.fetch(:root_cluster, 2))
        raise FormatError, "Invalid root cluster" if root.zero? && !root_cluster.between?(2, 0x0FFFFFFF)

        bytes = "\0".b * 512
        bytes[0, 3] = "\xEB\x3C\x90".b
        bytes[11, 2] = [bps].pack("v")
        bytes.setbyte(13, spc)
        bytes[14, 2] = [reserved].pack("v")
        bytes.setbyte(16, fats)
        bytes[17, 2] = [root].pack("v")
        bytes[32, 4] = [total].pack("V")
        bytes.setbyte(21, media)
        if root.zero?
          bytes[36, 4] = [fatsz].pack("V")
          bytes[44, 4] = [root_cluster].pack("V")
        else
          bytes[22, 2] = [fatsz].pack("v")
        end
        bytes[510, 2] = "\x55\xAA".b
        new(bytes, available_size: available_size)
      rescue KeyError, ArgumentError, TypeError, RangeError, ZeroDivisionError => e
        raise FormatError, "Invalid manual geometry: #{e.message}"
      end

      def cluster_size
        bytes_per_sector * sectors_per_cluster
      end

      def byte_size
        total_sectors * bytes_per_sector
      end

      def cluster_offset(cluster)
        raise OutOfRangeError, "Invalid cluster #{cluster}" unless cluster.between?(2, cluster_count + 1)

        (first_data_sector + ((cluster - 2) * sectors_per_cluster)) * bytes_per_sector
      end

      def to_h
        { fat_type: fat_type, bytes_per_sector: bytes_per_sector, sectors_per_cluster: sectors_per_cluster,
          reserved_sectors: reserved_sectors, fat_count: fat_count, fat_sectors: fat_sectors,
          root_entry_count: root_entry_count, root_cluster: root_cluster, total_sectors: total_sectors,
          cluster_count: cluster_count, label: label }
      end

      private

      def validate_geometry(available_size)
        raise FormatError, "Invalid FAT sector size" unless [512, 1024, 2048, 4096].include?(bytes_per_sector)
        unless sectors_per_cluster.between?(1, 128) && (sectors_per_cluster & (sectors_per_cluster - 1)).zero?
          raise FormatError, "Invalid FAT cluster size"
        end
        unless reserved_sectors.positive? && [1, 2].include?(fat_count) &&
               total_sectors.positive? && fat_sectors.positive?
          raise FormatError, "Invalid FAT geometry"
        end
        raise FormatError, "Invalid FAT media byte" unless media == 0xF0 || media.between?(0xF8, 0xFF)
        raise FormatError, "FAT volume exceeds source" if available_size && byte_size > available_size
      end

      def validate_fat(bytes)
        bits = fat_type.delete_prefix("FAT").to_i
        required_bytes = (((cluster_count + 2) * bits) + 7) / 8
        raise FormatError, "Allocation table is too short" if required_bytes > fat_sectors * bytes_per_sector

        if fat_type == "FAT32"
          unless root_entry_count.zero? && root_cluster.between?(2, cluster_count + 1) &&
                 bytes.byteslice(22, 2).unpack1("v").zero?
            raise FormatError, "Invalid FAT32 root geometry"
          end
        elsif root_entry_count.zero?
          raise FormatError, "Missing fixed root directory"
        end
      end
    end
  end
end
