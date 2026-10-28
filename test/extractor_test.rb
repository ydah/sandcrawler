# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class ExtractorTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @out = File.join(@tmp, "rescue")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_feature_is_available
    assert Sandcrawler.const_defined?(:Extractor), "safe extraction must be implemented"
  end

  def test_paths_are_portable_and_collisions_preserve_both_files
    extractor = Sandcrawler::Extractor.new(@out, source: { type: "image" })
    %w[../CON.txt /A:B.txt a?b.TXT C:\\NUL].each do |path|
      extractor.write(path: path, data: path.b)
    end
    manifest = extractor.finish
    outputs = manifest[:files].map { |entry| entry[:output] }
    assert_equal 4, outputs.map(&:downcase).uniq.size
    outputs.each do |path|
      assert_match %r{\Afiles/[^/]+\z}, path
      refute_match(/[<>:"\\|?*]/, path)
      assert File.file?(File.join(@out, path))
    end
    assert_equal "files/_CON.txt", outputs.first
    assert_includes outputs, "files/a_b~2.TXT"
  end

  def test_nested_names_keep_the_same_sanitized_parent
    extractor = Sandcrawler::Extractor.new(@out, source: {})
    extractor.directory(path: "a:b")
    extractor.write(path: "a:b/one", data: "1")
    extractor.write(path: "a:b/two", data: "2")
    extractor.write(path: "a?b/three", data: "3")
    assert_equal "1", File.read(File.join(@out, "files/a_b/one"))
    assert_equal "2", File.read(File.join(@out, "files/a_b/two"))
    assert_equal "3", File.read(File.join(@out, "files/a_b~2/three"))
  end

  def test_manifest_hash_partial_suffix_and_timestamp
    extractor = Sandcrawler::Extractor.new(@out, source: { sha256: "source" })
    time = Time.utc(2020, 1, 2, 3, 4, 6)
    entry = extractor.write(path: "home/app.rb", data: "puts 1\n", status: "truncated", mtime: time)
    assert_equal "files/home/app.rb.partial", entry[:output]
    assert_equal Digest::SHA256.hexdigest("puts 1\n"), entry[:sha256]
    assert_equal time, File.mtime(File.join(@out, entry[:output]))
    result = extractor.finish
    assert_equal result[:files].size, JSON.parse(File.read(File.join(@out, "manifest.json")))["files"].size
    assert File.file?(File.join(@out, "sandcrawler.log"))
    assert_includes File.read(File.join(@out, "sandcrawler.log")), "files=1"
  end

  def test_existing_output_requires_force_and_never_follows_symlinks
    FileUtils.mkdir_p(@out)
    File.write(File.join(@out, "keep"), "untouched")
    assert_raises(Sandcrawler::SafetyError) { Sandcrawler::Extractor.new(@out, source: {}) }
    extractor = Sandcrawler::Extractor.new(@out, source: {}, force: true)
    File.symlink(@tmp, File.join(@out, "files"))
    assert_raises(Sandcrawler::SafetyError) { extractor.write(path: "escape", data: "bad") }
    refute File.exist?(File.join(@tmp, "escape"))
    assert_equal "untouched", File.read(File.join(@out, "keep"))
  rescue NotImplementedError, Errno::EPERM
    skip "symlinks unavailable"
  end

  def test_directory_and_file_with_same_name_are_disambiguated
    extractor = Sandcrawler::Extractor.new(@out, source: {})
    extractor.write(path: "same", data: "file")
    extractor.write(path: "same/child", data: "child")
    assert_equal "file", File.read(File.join(@out, "files/same"))
    assert_equal "child", File.read(File.join(@out, "files/same~2/child"))
  end

  def test_failed_stream_is_recorded_without_leaving_temporary_files
    stream = Object.new
    def stream.read(*)
      raise IOError, "device disappeared"
    end
    extractor = Sandcrawler::Extractor.new(@out, source: {})
    result = extractor.write(path: "bad", data: stream)
    assert_equal "read_error", result[:status]
    assert_nil result[:output]
    assert_empty Dir.glob(File.join(@out, "**", ".sandcrawler-*"))
    assert_equal 1, extractor.finish[:warnings].size
  end

  def test_timestamp_failure_keeps_the_recovered_file_in_manifest
    extractor = Sandcrawler::Extractor.new(@out, source: {})
    File.stub(:utime, ->(*) { raise Errno::EINVAL, "timestamp unsupported" }) do
      entry = extractor.write(path: "app.rb", data: "puts 1", mtime: Time.utc(1980))
      assert_equal "ok", entry[:status]
      assert_equal "files/app.rb", entry[:output]
      assert_equal Digest::SHA256.hexdigest("puts 1"), entry[:sha256]
    end
  end

  def test_invalid_posix_filename_bytes_do_not_break_manifest
    extractor = Sandcrawler::Extractor.new(@out, source: {})
    entry = extractor.write(path: "bad\xFF.rb".b, data: "puts 1")
    assert_equal "626164ff2e7262", entry[:original_name_hex]
    extractor.finish
    assert File.file?(File.join(@out, "manifest.json"))
  end
end
