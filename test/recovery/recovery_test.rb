# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fat_builder"

class RecoveryTest < Minitest::Test
  include FatBuilder

  def test_recovery_layers_exist
    assert defined?(Sandcrawler::Recovery::Undelete), "recovery must exist"
  end

  def test_deleted_lfn_and_content
    fixture = build_fat(deleted: true, lfn: true)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_empty volume.each_entry.to_a
    entry, result = Sandcrawler::Recovery::Undelete.new(volume).each.first
    assert_equal "日本語のファイル名.rb", entry.name
    assert_equal "puts 'hello'", result.data
    refute_equal "ok", result.status
  end

  def test_deleted_file_stops_at_allocated_cluster
    fixture = build_fat(deleted: true)
    change_fat(fixture, 2, 0xFFF)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    _, result = Sandcrawler::Recovery::Undelete.new(volume).each.first
    assert_empty result.data
    assert_equal "partial", result.status
  end

  def test_deleted_recovery_does_not_read_a_live_file_with_a_damaged_free_fat_entry
    fixture = build_fat(deleted: true)
    fixture[:bytes][fixture[:root] + 32, 32] = short_entry("LIVE    RB ", 2, 12)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    _, result = Sandcrawler::Recovery::Undelete.new(volume).each.first
    assert_empty result.data
    assert_equal "partial", result.status
  end

  def test_orphan_chain_and_cycle_are_recovered_once
    fixture = build_fat
    fixture[:bytes][fixture[:root], 512] = "\xFF".b * 512
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    recovered = Sandcrawler::Recovery::Orphans.new(volume).each.to_a
    assert_equal 1, recovered.size
    assert_match(/CHAIN_2/, recovered[0][0].path)
    assert recovered[0][1].data.start_with?("puts 'hello'")
    change_fat(fixture, 2, 3)
    change_fat(fixture, 3, 2)
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    assert_equal 1, Sandcrawler::Recovery::Orphans.new(volume).each.to_a.size
  end

  def test_carving_classifies_and_joins_adjacent_text
    bytes = ("\xFF".b * 16) + "puts 'hi'\n".ljust(32, " ") + ("\0" * 16)
    carver = Sandcrawler::Recovery::Carver.new(source_for(bytes), block_size: 16)
    records = carver.each.to_a
    assert_equal 1, records.size
    assert_equal "00000010.txt", records[0][0].path
    assert_equal 32, records[0][1].data.bytesize
    assert_equal "erased", carver.classify("\xFF".b * 16)
    assert_equal "zero", carver.classify("\0" * 16)
    assert_equal "binary", carver.classify("\x01" * 16)
  end
end
