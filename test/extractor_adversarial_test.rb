# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class ExtractorAdversarialTest < Minitest::Test
  def with_output
    Dir.mktmpdir do |dir|
      yield Sandcrawler::Extractor.new(File.join(dir, "out"), source: { path: "bad\xFF.bin".b }), dir
    end
  end

  def test_invalid_utf8_names_and_source_metadata_remain_auditable
    with_output do |output, _dir|
      name = "bad\xFF.rb".dup.force_encoding(Encoding::UTF_8)
      entry = output.write(path: name, data: "puts 1")
      assert_equal "ok", entry[:status]
      manifest = output.finish
      assert_equal "626164ff2e7262", manifest[:files].first[:original_name_hex]
      assert_equal "626164ff2e62696e", manifest[:source][:path_hex]
      assert JSON.parse(File.read(File.join(output.out, "manifest.json")))
    end
  end

  def test_read_error_preserves_readable_prefix_and_existing_complete_copy
    with_output do |output, _dir|
      output.write(path: "app.rb", data: "older complete copy")
      stream = Object.new
      reads = 0
      stream.define_singleton_method(:read) do |_length, buffer = nil|
        reads += 1
        raise IOError, "source disconnected" if reads > 1

        buffer ? buffer.replace("readable prefix") : "readable prefix"
      end
      result = output.write(path: "broken.rb", data: stream)
      assert_equal "read_error", result[:status]
      refute_nil result[:output]
      assert_match(/\.partial\z/, result[:output])
      assert_equal "readable prefix", File.binread(File.join(output.out, result[:output]))
      assert_equal Digest::SHA256.hexdigest("readable prefix"), result[:sha256]
      assert_equal "older complete copy", File.read(File.join(output.out, "files/app.rb"))
    end
  end

  def test_directory_creation_failure_is_recorded_and_other_files_continue
    with_output do |output, _dir|
      output.directory(path: "files-ready")
      original = Dir.method(:mkdir)
      operation = lambda do |path, *arguments|
        raise Errno::EACCES, "blocked directory" if File.basename(path) == "blocked"

        original.call(path, *arguments)
      end
      Dir.stub(:mkdir, operation) { output.directory(path: "blocked") }
      output.write(path: "healthy.rb", data: "puts 1")
      manifest = output.finish
      assert_equal "ok", manifest[:files].first[:status]
      assert(manifest[:warnings].any? { |warning| warning[:code] == "DIRECTORY_WRITE_ERROR" })
      assert_equal "blocked", manifest[:directories].find { |entry| entry[:status] != "ok" }[:path]
    end
  end

  def test_empty_directory_original_name_is_recorded
    with_output do |output, _dir|
      output.directory(path: "CON", attributes: ["directory"])
      directory = output.finish[:directories].first
      assert_equal "CON", directory[:original_name]
      assert_equal "files/_CON", directory[:output]
      assert_equal ["directory"], directory[:attributes]
    end
  end

  def test_early_eof_does_not_certify_a_complete_file
    with_output do |output, _dir|
      entry = output.write(path: "short.bin", data: StringIO.new("abc"), expected_size: 6)
      assert_equal "truncated", entry[:status]
      assert_equal "files/short.bin.partial", entry[:output]
      assert_equal "abc", File.binread(File.join(output.out, entry[:output]))
    end
  end

  def test_invalid_filename_and_stream_failure_are_logged_without_console_controls
    Dir.mktmpdir do |dir|
      messages = StringIO.new
      output = Sandcrawler::Extractor.new(File.join(dir, "out"), source: {},
                                                                 log: Sandcrawler::Log.new(io: messages))
      stream = Object.new
      stream.define_singleton_method(:read) { |*| raise IOError, "disconnected" }
      entry = output.write(path: "bad\xFF\e[31m.rb".dup.force_encoding(Encoding::UTF_8), data: stream)
      assert_equal "read_error", entry[:status]
      assert messages.string.valid_encoding?
      refute_includes messages.string, "\e"
      assert_equal 1, output.finish[:files].size
    end
  end

  def test_different_invalid_directory_names_do_not_merge
    with_output do |output, _dir|
      first = "bad\xFF".dup.force_encoding(Encoding::UTF_8)
      second = "bad\xFE".dup.force_encoding(Encoding::UTF_8)
      output.directory(path: first)
      output.directory(path: second)
      output.write(path: "#{first}/one", data: "first")
      output.write(path: "#{second}/two", data: "second")
      manifest = output.finish
      directories = manifest[:directories].map { |entry| entry[:output] }
      assert_equal 2, directories.uniq.size
      assert_equal "first", File.read(File.join(output.out, directories[0], "one"))
      assert_equal "second", File.read(File.join(output.out, directories[1], "two"))
    end
  end
end
