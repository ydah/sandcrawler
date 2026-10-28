# frozen_string_literal: true

require_relative "../fat/volume"

module Sandcrawler
  module Recovery
    class Undelete
      def initialize(volume)
        @volume = volume
      end

      def each
        return enum_for(__method__) unless block_given?

        @volume.each_entry(deleted: true).to_a.each do |entry|
          next unless entry.deleted? && !entry.directory?

          warnings = [{ code: "DELETED_GUESS",
                        detail: "Contiguous free clusters assumed; verify recovered content manually" }]
          data = "".b
          status = "recovered"
          count = (entry.size + @volume.boot_sector.cluster_size - 1) / @volume.boot_sector.cluster_size
          count.times do |index|
            cluster = entry.first_cluster + index
            unless cluster.between?(2, @volume.boot_sector.cluster_count + 1) &&
                   @volume.allocation_table[cluster].zero? && !@volume.referenced_clusters.include?(cluster)
              status = "partial"
              warnings << { code: "DELETED_OVERLAP", detail: "Stopped at occupied or invalid cluster #{cluster}" }
              break
            end
            data << @volume.read_cluster(cluster)
          rescue Error, IOError, SystemCallError => e
            status = "read_error"
            warnings << { code: "READ_ERROR", detail: "#{entry.path}, cluster #{cluster}: #{e.message}" }
            break
          end
          yield entry, FAT::Volume::ReadResult.new(data: data.byteslice(0, entry.size), status: status,
                                                   warnings: warnings)
        end
      end
    end
  end
end
