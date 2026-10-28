# frozen_string_literal: true

require_relative "../test_helper"
require "digest"

class GeneratedFixturesTest < Minitest::Test
  def test_mtools_reference_trees_match
    fixtures = Dir[File.expand_path("../fixtures/generated/*.expected", __dir__)]
    skip "Run rake fixtures to build dosfstools/mtools fixtures" if fixtures.empty?
    fixtures.each do |expected|
      image = Sandcrawler::Image.open(expected.sub(/\.expected\z/, ".img"))
      volume = Sandcrawler::FAT::Volume.new(image)
      actual = volume.each_entry.reject(&:directory?).to_h do |entry|
        result = volume.read(entry)
        assert_equal "ok", result.status, "#{expected}: #{entry.path} #{result.warnings}"
        [entry.path, Digest::SHA256.hexdigest(result.data)]
      end
      paths = Dir.glob("**/*", base: expected).select do |path|
        File.file?(File.join(expected, path))
      end
      reference = paths.to_h do |path|
        [path, Digest::SHA256.file(File.join(expected, path)).hexdigest]
      end
      assert_equal reference, actual, expected
    ensure
      image&.close
    end
  end
end
