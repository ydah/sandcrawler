# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fat_builder"

class FatAdversarialTest < Minitest::Test
  include FatBuilder

  def test_erased_allocation_metadata_cannot_certify_a_small_file
    fixture = build_fat
    fixture[:bytes][fixture[:reserved] * 512, fixture[:fatsz] * 1024] = "\xFF".b * (fixture[:fatsz] * 1024)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    result = volume.read(volume.each_entry.first)
    assert_equal "chain_error", result.status
    assert_equal "puts 'hello'", result.data
    assert_includes result.warnings.map { |warning| warning[:code] }, "FAT_ERASED_ENTRY"
    assert_empty Sandcrawler::Recovery::Orphans.new(volume).each.to_a
  end

  def test_live_entries_after_a_directory_end_marker_are_not_resurrected
    fixture = build_fat(deleted: true)
    stale = short_entry("STALE   TXT", 2, 12)
    fixture[:bytes][fixture[:root] + 64, 32] = stale
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    entries = volume.each_entry(deleted: true).to_a
    assert_equal ["_pp.rb"], entries.map(&:name)
    assert_equal "puts 'hello'", Sandcrawler::Recovery::Undelete.new(volume).each.first.last.data
  end

  def test_long_names_larger_than_fat_limit_fall_back_to_short_name
    short = short_entry("APP     RB ", 2, 12)
    lfn = Sandcrawler::FAT::LfnAssembler.new
    lfn_entries("a" * 256, short[0, 11]).scan(/.{32}/m).each { |entry| lfn.add(entry) }
    assert_nil lfn.take(short)
  end

  def test_unreadable_orphan_cluster_does_not_discard_readable_tail
    fixture = build_fat
    change_fat(fixture, 3, 4)
    change_fat(fixture, 4, 0xFFF)
    fixture[:bytes][(fixture[:first] + 2) * 512, 512] = "rescuable".ljust(512, " ")
    source = source_for(fixture[:bytes])
    bad_offset = (fixture[:first] + 1) * 512
    original = source.method(:read_at)
    source.define_singleton_method(:read_at) do |offset, length|
      raise IOError, "unreadable cluster" if offset == bad_offset

      original.call(offset, length)
    end
    volume = Sandcrawler::FAT::Volume.new(source)
    fragments = Sandcrawler::Recovery::Orphans.new(volume).each.to_a
    assert fragments.any? { |_entry, result| result.data.start_with?("rescuable") }, "readable tail must be rescued"
  end

  def test_crosslinked_files_are_both_marked_uncertain_during_streamed_extraction
    fixture = build_fat
    fixture[:bytes][fixture[:root] + 32, 32] = short_entry("OTHER   RB ", 2, 12)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    results = []
    volume.each_entry { |entry| results << volume.read(entry) }
    assert_equal %w[chain_error chain_error], results.map(&:status)
    results.each { |result| assert_includes result.warnings.map { |warning| warning[:code] }, "CROSS_LINK" }
  end

  def test_identical_live_names_in_distinct_slots_are_ambiguous
    fixture = build_fat
    fixture[:bytes][fixture[:root] + 32, 32] = fixture[:bytes][fixture[:root], 32]
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    results = volume.each_entry.map { |entry| volume.read(entry) }
    assert_equal %w[chain_error chain_error], results.map(&:status)
    assert_includes volume.warnings.map { |warning| warning[:code] }, "DUPLICATE_ENTRY"
    results.each { |result| assert_includes result.warnings.map { |warning| warning[:code] }, "DUPLICATE_ENTRY" }
  end

  def test_conflicting_directory_names_are_reported
    fixture = build_fat
    fixture[:bytes][fixture[:root], 64] = short_entry("HOME       ", 3, 0, attr: 0x10) +
                                          short_entry("HOME       ", 4, 0, attr: 0x10)
    [3, 4].each { |cluster| change_fat(fixture, cluster, 0xFFF) }
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    volume.each_entry.to_a
    assert_includes volume.warnings.map { |warning| warning[:code] }, "DUPLICATE_ENTRY"
  end

  def test_structural_dot_entries_do_not_depend_on_codepage
    fixture = build_fat
    fixture[:bytes][fixture[:root], 32] = short_entry(".          ", 2, 0, attr: 0x10)
    fixture[:bytes][fixture[:root] + 32, 32] = short_entry("..         ", 0, 0, attr: 0x10)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]), codepage: "UTF-16")
    assert_empty volume.each_entry.to_a
    assert_empty volume.warnings
  end

  def test_seeded_metadata_corruption_is_bounded_and_never_certifies_short_reads
    random = Random.new(20_261_028)
    200.times do
      fixture = build_fat(lfn: true)
      1.upto(random.rand(1..8)) do
        offset = random.rand(fixture[:first] * 512)
        fixture[:bytes].setbyte(offset, random.rand(256))
      end
      begin
        volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
      rescue Sandcrawler::FormatError
        next
      end
      entries = volume.each_entry.to_a
      assert_operator entries.length, :<=, 32 + (32 * 16)
      entries.reject(&:directory?).each do |entry|
        result = volume.read(entry)
        assert_equal Encoding::BINARY, result.data.encoding
        assert_operator result.data.bytesize, :<=, entry.size
        assert_equal entry.size, result.data.bytesize if result.status == "ok"
      end
    end
  end

  def test_fat12_link_crossing_sectors_survives_mixed_copy_selection
    boot = Sandcrawler::FAT::BootSector.from_geometry(
      { bps: 512, spc: 1, rsvd: 1, fats: 2, fatsz: 3, root: 32, total: 709 }, available_size: 709 * 512
    )
    bytes = "\0".b * boot.byte_size
    table = "\0".b * (3 * 512)
    set_fat(table, 340, 341, 12)
    set_fat(table, 341, 342, 12)
    set_fat(table, 342, 0xFFF, 12)
    bytes[512, table.bytesize] = table
    bytes[4 * 512, table.bytesize] = table
    bytes[512, 512] = "\xFF".b * 512
    bytes[5 * 512, 512] = "\xFF".b * 512
    allocation = Sandcrawler::FAT::AllocationTable.new(source_for(bytes), boot)
    assert_equal "mixed", allocation.selection
    assert_equal [340, 341, 342], allocation.chain(340).clusters
    assert_equal "ok", allocation.chain(340).status
  end

  def test_fat32_backup_boot_sector_recovers_the_original_volume_base
    fixture = build_fat(bits: 32)
    fixture[:bytes][50, 2] = [6].pack("v")
    fixture[:bytes][6 * 512, 512] = fixture[:bytes][0, 512]
    fixture[:bytes][0, 512] = "\xFF".b * 512
    source = source_for(fixture[:bytes] + ("\xFF".b * 4096))
    candidates = Sandcrawler::FAT::VolumeLocator.new(source).candidates
    assert_equal [0], candidates.map(&:offset)
    assert_equal 3072, candidates.first.boot_sector_offset
    assert_equal "BACKUP_BOOT_SECTOR", candidates.first.warnings.first[:code]
    volume = Sandcrawler::FAT::Volume.new(source, offset: candidates.first.offset,
                                                  boot_sector: candidates.first.boot_sector)
    assert_equal "puts 'hello'", volume.read(volume.each_entry.first).data
    exact_source = source_for(fixture[:bytes])
    assert_equal [0], Sandcrawler::FAT::VolumeLocator.new(exact_source).candidates.map(&:offset)
  end

  def test_fat32_primary_boot_sector_is_not_shifted_to_an_earlier_base
    fixture = build_fat(bits: 32)
    fixture[:bytes][50, 2] = [6].pack("v")
    source = source_for(("\xFF".b * 4096) + fixture[:bytes])
    candidate = Sandcrawler::FAT::VolumeLocator.new(source).candidates.first
    assert_equal 4096, candidate.offset
    assert_empty candidate.warnings
  end
end
