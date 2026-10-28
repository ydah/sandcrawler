# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/uf2_builder"
require "minitest/mock"

class Uf2ValidationTest < Minitest::Test
  include Uf2Builder

  def with_uf2(bytes)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "image.uf2")
      File.binwrite(path, bytes)
      yield path
    end
  end

  def test_missing_blocks_are_reported_even_when_address_space_has_no_gap
    with_uf2(uf2_block("text", number: 0, total: 3)) do |path|
      image = Sandcrawler::Image.open(path)
      assert_includes image.warnings.map { |warning| warning[:code] }, "UF2_INCOMPLETE"
    end
  end

  def test_unordered_blocks_and_no_flash_blocks
    bytes = uf2_block("second", offset: 6, number: 1, total: 3) +
            uf2_block("first!", number: 0, total: 3) +
            uf2_block("ignored", offset: 0x10000000, number: 2, total: 3, flags: 1)
    with_uf2(bytes) { |path| assert_equal "first!second", Sandcrawler::Image.open(path).read_at(0, 12) }
  end

  def test_bad_payload_address_flags_magic_and_block_number
    blocks = [uf2_block("a", flags: 0x1000), uf2_block("a", offset: -1), uf2_block("a", offset: 0x1000000),
              uf2_block("a", number: 1, total: 1)]
    invalid = uf2_block("a")
    invalid.setbyte(508, 0)
    blocks << invalid
    blocks.each do |bytes|
      with_uf2(bytes) { |path| assert_raises(Sandcrawler::FormatError) { Sandcrawler::Image.open(path) } }
    end
  end

  def test_overlapping_and_inconsistent_blocks
    cases = [uf2_block("first", total: 2) + uf2_block("conflict", offset: 2, number: 1, total: 2),
             uf2_block("first", total: 2) + uf2_block("second", offset: 512, number: 1, total: 3)]
    cases.each do |bytes|
      with_uf2(bytes) { |path| assert_raises(Sandcrawler::FormatError) { Sandcrawler::Image.open(path) } }
    end
  end

  def test_truncation_between_size_check_and_block_read_is_a_format_error
    io = StringIO.new([0x0A324655, 0x9E5D5157].pack("V*"))
    io.define_singleton_method(:size) { 512 }
    File.stub(:open, ->(*, &block) { block.call(io) }) do
      assert_raises(Sandcrawler::FormatError) { Sandcrawler::Image::Uf2Image.new("truncated.uf2") }
    end
  end

  def test_seeded_uf2_header_mutations_never_escape_as_untyped_errors
    random = Random.new(20_261_028)
    100.times do
      bytes = uf2_block("payload")
      3.times { bytes.setbyte(random.rand(32), random.rand(256)) }
      with_uf2(bytes) do |path|
        source = Sandcrawler::Image.open(path)
        result = source.read_at([source.size - 16, 0].max, [source.size, 16].min)
        assert_equal Encoding::BINARY, result.encoding
        assert_operator result.bytesize, :<=, 16
      rescue Sandcrawler::FormatError
        assert true
      end
    end
  end
end
