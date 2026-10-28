# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fat_builder"

class ReadErrorsTest < Minitest::Test
  include FatBuilder

  class FailingSource < FatBuilder::MemorySource
    def initialize(bytes, failure_offset, error)
      super(bytes)
      @failure_offset = failure_offset
      @error = error
    end

    def read_at(offset, length)
      raise @error if offset == @failure_offset

      super
    end
  end

  def test_unreadable_directory_does_not_hide_siblings
    fixture = build_fat
    fixture[:bytes][fixture[:root] + 32, 64] = short_entry("BAD        ", 3, 0, attr: 0x10) +
                                               short_entry("GOOD       ", 4, 0, attr: 0x10)
    [3, 4, 5].each { |cluster| change_fat(fixture, cluster, 0xFFF) }
    fixture[:bytes][cluster_offset(fixture, 4), 32] = short_entry("SAFE    TXT", 5, 4)
    volume = failing_volume(fixture, 3, IOError.new("directory unavailable"))

    paths = recover_without_abort { volume.each_entry.map(&:path) }
    assert_includes paths, "GOOD/SAFE.TXT"
    assert_includes volume.warnings.map { |warning| warning[:code] }, "DIRECTORY_ERROR"
  end

  def test_undelete_keeps_prefix_and_continues_after_read_error
    fixture = build_fat(deleted: true)
    fixture[:bytes][fixture[:entry_offset] + 28, 4] = [1024].pack("V")
    later = short_entry("LATER   TXT", 4, 4)
    later.setbyte(0, 0xE5)
    fixture[:bytes][fixture[:root] + 32, 32] = later
    fixture[:bytes][cluster_offset(fixture, 4), 4] = "safe"
    volume = failing_volume(fixture, 3, Errno::EIO.new("cluster unavailable"))

    records = recover_without_abort { Sandcrawler::Recovery::Undelete.new(volume).each.to_a }
    assert_equal(%w[read_error recovered], records.map { |_, result| result.status })
    assert_equal 512, records[0][1].data.bytesize
    assert records[0][1].data.start_with?("puts 'hello'")
    assert_equal "READ_ERROR", records[0][1].warnings.last[:code]
    assert_equal "safe", records[1][1].data
  end

  def test_orphans_keep_prefix_and_continue_after_read_error
    fixture = build_fat
    fixture[:bytes][fixture[:root], 32] = "\0" * 32
    change_fat(fixture, 2, 3)
    [3, 4].each { |cluster| change_fat(fixture, cluster, 0xFFF) }
    fixture[:bytes][cluster_offset(fixture, 4), 4] = "safe"
    volume = failing_volume(fixture, 3, IOError.new("cluster unavailable"))

    records = recover_without_abort { Sandcrawler::Recovery::Orphans.new(volume).each.to_a }
    assert_equal(%w[read_error recovered], records.map { |_, result| result.status })
    assert_equal 512, records[0][1].data.bytesize
    assert records[0][1].data.start_with?("puts 'hello'")
    assert_equal "READ_ERROR", records[0][1].warnings.last[:code]
    assert records[1][1].data.start_with?("safe")
  end

  def test_carving_separates_fragments_at_unreadable_block_and_continues
    source = FailingSource.new(("a" * 16) + ("b" * 16) + ("c" * 16), 16, Errno::EIO.new("block unavailable"))
    records = recover_without_abort { Sandcrawler::Recovery::Carver.new(source, block_size: 16).each.to_a }

    assert_equal(%w[carved read_error carved], records.map { |_, result| result.status })
    assert_equal(["a" * 16, "", "c" * 16], records.map { |_, result| result.data })
    assert_equal(%w[00000000.txt 00000010.txt 00000020.txt], records.map { |entry, _| entry.path })
    assert_equal 16, records[1][0].size
    assert_equal "READ_ERROR", records[1][1].warnings.last[:code]
  end

  private

  def recover_without_abort
    yield
  rescue Sandcrawler::Error, IOError, SystemCallError => e
    flunk "Recovery aborted instead of isolating unreadable data: #{e.class}: #{e.message}"
  end

  def cluster_offset(fixture, cluster)
    (fixture[:first] + cluster - 2) * fixture[:bps]
  end

  def failing_volume(fixture, cluster, error)
    source = FailingSource.new(fixture[:bytes], cluster_offset(fixture, cluster), error)
    Sandcrawler::FAT::Volume.new(source)
  end
end
