# frozen_string_literal: true

require_relative "../fat/volume"

module Sandcrawler
  module Recovery
    class Orphans
      def initialize(volume)
        @volume = volume
      end

      def each
        return enum_for(__method__) unless block_given?

        @volume.each_entry.to_a
        allocation = @volume.allocation_table
        remaining = Set.new((2..(@volume.boot_sector.cluster_count + 1)).select do |cluster|
          allocation.allocated?(cluster) && !@volume.referenced_clusters.include?(cluster)
        end)
        pointed_to = Set.new(remaining.filter_map do |cluster|
          allocation[cluster] if remaining.include?(allocation[cluster])
        end)
        roots = (remaining - pointed_to).to_a + remaining.to_a
        roots.each do |first|
          next unless remaining.include?(first)

          chain = allocation.chain(first)
          clusters = chain.clusters.take_while { |cluster| remaining.include?(cluster) }
          warnings = chain.warnings + [
            { code: "ORPHAN_CHAIN", detail: "Chain has no directory entry; original name and file length are unknown" }
          ]
          data = "".b
          status = chain.status == "ok" ? "recovered" : chain.status
          clusters.each do |cluster|
            remaining.delete(cluster)
            data << @volume.read_cluster(cluster)
          rescue Error, IOError, SystemCallError => e
            status = "read_error"
            warnings << { code: "READ_ERROR", detail: "Chain #{first}, cluster #{cluster}: #{e.message}" }
            break
          end
          text = data.dup.force_encoding("UTF-8")
          extension = text.valid_encoding? && text.match?(/\b(?:def|end|require|class|module|puts)\b/) ? "rb" : "bin"
          entry = FAT::DirEntry.recovered(path: "CHAIN_#{first}.#{extension}", size: data.bytesize,
                                          first_cluster: first)
          result = FAT::Volume::ReadResult.new(data: data, status: status, warnings: warnings)
          yield entry, result
        end
      end
    end
  end
end
