# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fat_builder"

class FatTest < Minitest::Test
  include FatBuilder

  def test_fat_layers_exist
    assert defined?(Sandcrawler::FAT::Volume), "FAT volume reader must exist"
  end

  def test_fat_types_and_content
    [12, 16, 32].each do |bits|
      fixture = build_fat(bits: bits)
      volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
      assert_equal "FAT#{bits}", volume.boot_sector.fat_type
      entry = volume.each_entry.to_a.fetch(0)
      assert_equal "app.rb", entry.path
      assert_equal "puts 'hello'", volume.read(entry).data
      assert_equal "ok", volume.read(entry).status
      assert_nil entry.mtime
    end
  end

  def test_large_sectors_and_locating_embedded_volume
    fixture = build_fat(bps: 4096)
    image = source_for(("\xFF".b * 0x100000) + fixture[:bytes])
    candidate = Sandcrawler::FAT::VolumeLocator.new(image).candidates.first
    assert_equal 0x100000, candidate.offset
    assert_equal 4096, candidate.boot_sector.bytes_per_sector
    assert_operator candidate.score, :>, 0
  end

  def test_japanese_lfn_and_invalid_checksum_fallback
    fixture = build_fat(lfn: true)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_equal "日本語のファイル名.rb", volume.each_entry.first.name
    fixture[:bytes].setbyte(fixture[:root] + 13, 0)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_equal "app.rb", volume.each_entry.first.name
  end

  def test_fat_copy_repair_and_forced_selection
    fixture = build_fat
    fixture[:bytes][fixture[:reserved] * 512, 512] = "\xFF".b * 512
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_equal "ok", volume.read(volume.each_entry.first).status
    assert_includes volume.warnings.map { |warning| warning[:code] }, "FAT_MISMATCH"
    assert_equal "fat2", volume.metadata[:fat_selection]
    forced = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]), fat: 1)
    assert_equal "fat1", forced.metadata[:fat_selection]
  end

  def test_loop_truncation_and_erased_content
    fixture = build_fat
    fixture[:bytes][fixture[:entry_offset] + 28, 4] = [1024].pack("V")
    change_fat(fixture, 2, 2)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_equal "chain_error", volume.read(volume.each_entry.first).status
    change_fat(fixture, 2, 0xFFF)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_equal "truncated", volume.read(volume.each_entry.first).status
    fixture[:bytes][fixture[:entry_offset] + 28, 4] = [12].pack("V")
    fixture[:bytes][fixture[:first] * 512, 512] = "\xFF".b * 512
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_equal "suspect_erased", volume.read(volume.each_entry.first).status
  end

  def test_manual_geometry_and_corrupt_bpb
    fixture = build_fat
    source = source_for(fixture[:bytes])
    bp = Sandcrawler::FAT::BootSector.from_geometry({ bps: 512, spc: 1, rsvd: 1, fats: 2, fatsz: 1, root: 32 },
                                                    available_size: source.size)
    fixture[:bytes][0, 512] = "\xFF".b * 512
    assert_empty Sandcrawler::FAT::VolumeLocator.new(source).candidates
    volume = Sandcrawler::FAT::Volume.new(source, boot_sector: bp)
    assert_equal "puts 'hello'", volume.read(volume.each_entry.first).data
    assert_raises(Sandcrawler::FormatError) { Sandcrawler::FAT::BootSector.new("\0" * 512) }
  end
end
