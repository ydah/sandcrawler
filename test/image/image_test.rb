# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/uf2_builder"
require "tmpdir"
require "minitest/mock"

class ImageTest < Minitest::Test
  include Uf2Builder

  def test_raw_reader_falls_back_when_pread_is_not_implemented
    io = StringIO.new("abcdef")
    io.define_singleton_method(:pread) { |*| raise Errno::ENOSYS }
    File.stub(:open, io) do
      image = Sandcrawler::Image::RawImage.new("image.bin")
      assert_equal "cde", image.read_at(2, 3)
      assert_equal "ab", image.read_at(0, 2)
      assert_equal "".b, image.read_at(6, 0)
      image.close
      assert io.closed?
    end
  end

  def test_sources_are_implemented
    assert defined?(Sandcrawler::Image::RawImage), "raw image reader must exist"
  end

  def test_raw_and_slice_validate_bounds
    Dir.mktmpdir do |dir|
      path = File.join(dir, "raw.bin")
      File.binwrite(path, "abcdef")
      image = Sandcrawler::Image.open(path)
      assert_equal "bcd".b, image.read_at(1, 3)
      assert_equal Encoding::BINARY, image.read_at(0, 1).encoding
      assert_equal "cd", Sandcrawler::Image::Slice.new(image, 2, 3).read_at(0, 2)
      assert_raises(Sandcrawler::OutOfRangeError) { image.read_at(-1, 1) }
      assert_raises(Sandcrawler::OutOfRangeError) { image.read_at(5, 2) }
      assert_raises(Sandcrawler::OutOfRangeError) { Sandcrawler::Image::Slice.new(image, 5, 2) }
      image.close
    end
  end

  def test_sparse_uf2_and_duplicate_conflict
    Dir.mktmpdir do |dir|
      path = File.join(dir, "raw.uf2")
      File.binwrite(path, uf2_block("abcd", offset: 512))
      image = Sandcrawler::Image.open(path)
      assert_equal 516, image.size
      assert_equal "\xFF\xFFabcd".b, image.read_at(510, 6)
      assert_raises(Sandcrawler::OutOfRangeError) { image.read_at(516, 1) }
      File.binwrite(path, uf2_block("abcd") + uf2_block("efgh"))
      assert_raises(Sandcrawler::FormatError) { Sandcrawler::Image.open(path) }
      File.binwrite(path, "bad")
      assert_raises(Sandcrawler::FormatError) { Sandcrawler::Image.open(path) }
    end
  end

  def test_uf2_reads_across_adjacent_blocks_and_sparse_gaps
    Dir.mktmpdir do |dir|
      path = File.join(dir, "boundaries.uf2")
      blocks = uf2_block("ijkl", offset: 12, number: 2, total: 3) +
               uf2_block("abcd", offset: 0, number: 0, total: 3) +
               uf2_block("efgh", offset: 4, number: 1, total: 3)
      File.binwrite(path, blocks)
      image = Sandcrawler::Image.open(path)

      assert_equal "cdefgh\xFF\xFF\xFF\xFFij".b, image.read_at(2, 12)
      assert_equal "efgh", image.read_at(4, 4)
      assert_equal "\xFF\xFF\xFF\xFF".b, image.read_at(8, 4)
      assert_empty image.read_at(16, 0)
    end
  end
end
