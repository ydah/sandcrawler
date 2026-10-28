# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fat_builder"

class FatEdgeCasesTest < Minitest::Test
  include FatBuilder

  def test_nested_directory_loop_and_empty_file
    fixture = build_fat
    fixture[:bytes][fixture[:root], 32] = short_entry("HOME       ", 3, 0, attr: 0x10)
    change_fat(fixture, 3, 0xFFF)
    directory = (fixture[:first] + 1) * 512
    fixture[:bytes][directory, 32] = short_entry(".          ", 3, 0, attr: 0x10)
    fixture[:bytes][directory + 32, 32] = short_entry("..         ", 0, 0, attr: 0x10)
    fixture[:bytes][directory + 64, 32] = short_entry("APP     RB ", 2, 12)
    fixture[:bytes][directory + 96, 32] = short_entry("EMPTY   TXT", 0, 0)
    fixture[:bytes][directory + 128, 32] = short_entry("LOOP       ", 3, 0, attr: 0x10)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    entries = volume.each_entry.to_a
    assert_equal ["HOME", "HOME/APP.RB", "HOME/EMPTY.TXT", "HOME/LOOP"], entries.map(&:path)
    assert_equal "puts 'hello'", volume.read(entries[1]).data
    assert_equal "", volume.read(entries[2]).data
    assert_includes volume.warnings.map { |warning| warning[:code] }, "DIRECTORY_LOOP"
    assert_equal ["HOME"], volume.each_entry(recursive: false).map(&:path)
  end

  def test_bad_free_out_of_range_and_long_chains
    [0, 1, 0xFF7, 100, 3].each do |link|
      fixture = build_fat
      change_fat(fixture, 2, link)
      volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
      result = volume.read(volume.each_entry.first)
      assert_equal(link.zero? ? "truncated" : "chain_error", result.status, link.to_s)
      refute_empty result.warnings
    end
  end

  def test_truncated_fat_table_and_out_of_source_volume_are_rejected
    fixture = build_fat
    fixture[:bytes][19, 2] = [4000].pack("v")
    assert_raises(Sandcrawler::FormatError) { Sandcrawler::FAT::BootSector.new(fixture[:bytes]) }
    assert_raises(Sandcrawler::FormatError) do
      fixture = build_fat
      Sandcrawler::FAT::BootSector.new(fixture[:bytes], available_size: 512)
    end
    assert_raises(Sandcrawler::FormatError) do
      Sandcrawler::FAT::BootSector.from_geometry(
        { bps: -65_024, spc: 1, rsvd: 1, fats: 2, fatsz: 1, root: 32, total: 37 }, available_size: 100_000
      )
    end
    assert_raises(Sandcrawler::FormatError) do
      Sandcrawler::FAT::BootSector.from_geometry(
        { bps: 512, spc: 1, rsvd: 1, fats: 2, fatsz: 1, root: 32, total: 37, media: 504 }, available_size: 100_000
      )
    end
  end

  def test_mbr_candidate_and_small_input
    fixture = build_fat
    bytes = ("\0".b * 4096) + fixture[:bytes]
    bytes[510, 2] = "\x55\xAA".b
    bytes.setbyte(450, 1)
    bytes[454, 4] = [1].pack("V")
    assert_equal 4096, Sandcrawler::FAT::VolumeLocator.new(source_for(bytes)).candidates.first.offset
    assert_empty Sandcrawler::FAT::VolumeLocator.new(source_for("x")).candidates
  end

  def test_cp932_case_flags_and_invalid_dates
    entry = short_entry("TEST    TXT", 2, 1)
    entry.setbyte(12, 0x18)
    entry[24, 2] = [((2026 - 1980) << 9) | (10 << 5) | 28].pack("v")
    entry[22, 2] = [(13 << 11) | (20 << 5) | 15].pack("v")
    parsed = Sandcrawler::FAT::DirEntry.new(entry)
    assert_equal "test.txt", parsed.name
    assert_equal [2026, 10, 28, 13, 20, 30],
                 [parsed.mtime.year, parsed.mtime.month, parsed.mtime.day, parsed.mtime.hour, parsed.mtime.min,
                  parsed.mtime.sec]
    entry[24, 2] = [((2026 - 1980) << 9) | (2 << 5) | 30].pack("v")
    assert_nil Sandcrawler::FAT::DirEntry.new(entry).mtime
    entry[0, 8] = "日本".encode("CP932").b.ljust(8, " ")
    assert_equal "日本.txt", Sandcrawler::FAT::DirEntry.new(entry, codepage: "CP932").name
    entry.setbyte(0, 0x05)
    refute Sandcrawler::FAT::DirEntry.new(entry).deleted?
  end

  def test_fat32_high_bits_are_masked
    fixture = build_fat(bits: 32)
    change_fat(fixture, 3, 0xFFFFFFFF)
    fixture[:bytes][fixture[:entry_offset] + 20, 2] = [0xF000].pack("v")
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_equal 3, volume.each_entry.first.first_cluster
    assert_equal "ok", volume.read(volume.each_entry.first).status
  end

  def test_fat32_active_copy_when_mirroring_is_disabled
    fixture = build_fat(bits: 32)
    fixture[:bytes][40, 2] = [0x81].pack("v")
    first_fat = fixture[:reserved] * 512
    fixture[:bytes][first_fat + (3 * 4), 4] = [0].pack("V")
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_equal "ok", volume.read(volume.each_entry.first).status
    assert_equal "fat2", volume.metadata[:fat_selection]
  end

  def test_deleted_entries_after_end_marker_and_invalid_lfn_order
    fixture = build_fat(deleted: true)
    fixture[:bytes][fixture[:root] + 32, 32] = fixture[:bytes][fixture[:root], 32]
    fixture[:bytes][fixture[:root], 32] = "\0" * 32
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_empty volume.each_entry.to_a
    assert_equal ["_pp.rb"], volume.each_entry(deleted: true).map(&:name)
    fixture = build_fat(lfn: true)
    fixture[:bytes].setbyte(fixture[:root], 0x42)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_equal "app.rb", volume.each_entry.first.name
  end
end
