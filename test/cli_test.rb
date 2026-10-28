# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fat_builder"
require "minitest/mock"

class CLITest < Minitest::Test
  include FatBuilder

  def run_cli(*args, input: "")
    assert Sandcrawler.const_defined?(:CLI), "CLI must be implemented"
    out = StringIO.new
    err = StringIO.new
    code = Sandcrawler::CLI.new(stdout: out, stderr: err, stdin: StringIO.new(input)).run(args)
    [code, out.string, err.string]
  end

  def test_help_version_and_usage_errors
    assert_equal 0, run_cli("--help")[0]
    assert_equal "#{Sandcrawler::VERSION}\n", run_cli("--version")[1]
    assert_equal 2, run_cli("missing-command")[0]
    assert_equal 2, run_cli("extract")[0]
    assert_equal 2, run_cli("scan", "x", "--fat", "3")[0]
  end

  def test_carving_without_boot_sector_and_json_output
    Dir.mktmpdir do |dir|
      image = File.join(dir, "raw.bin")
      File.binwrite(image, "puts 'hello'\n".ljust(4096, " ") + ("\xFF".b * 4096))
      code, output, error = run_cli("extract", image, "--carve", "-o", File.join(dir, "out"), "--json")
      assert_equal 4, code, error
      manifest = JSON.parse(output)
      assert_equal Digest::SHA256.file(image).hexdigest, manifest.dig("source", "sha256")
      assert_equal 1, manifest["files"].size
      assert_match %r{\Acarved/}, manifest["files"][0]["output"]
    end
  end

  def test_image_cannot_be_overwritten_by_output
    Dir.mktmpdir do |dir|
      image = File.join(dir, "manifest.json")
      File.binwrite(image, "original")
      code, = run_cli("extract", image, "--carve", "--force", "-o", dir)
      assert_equal 1, code
      assert_equal "original", File.binread(image)
    end
  end

  def test_invalid_geometry_and_unknown_encoding_are_usage_errors
    assert_equal 2, run_cli("scan", "x", "--geometry", "oops=1")[0]
    assert_equal 2, run_cli("ls", "x", "--codepage", "imaginary")[0]
  end

  def test_manual_geometry_rejects_missing_duplicate_and_conflicting_fields
    base = "bps=512,spc=1,rsvd=1,fats=2,fatsz=1,root=32"
    ["bps=512", "#{base},bps=4096", "#{base},total=32,totsec=64"].each do |geometry|
      code, = run_cli("scan", "missing.bin", "--geometry", geometry)
      assert_equal 2, code, geometry
    end
    Dir.mktmpdir do |dir|
      path = File.join(dir, "source.bin")
      File.binwrite(path, build_fat[:bytes])
      code, = run_cli("scan", path, "--geometry", base.sub("spc=1", "spc=3"))
      assert_equal 2, code
    end
  end

  def test_directory_loss_returns_partial_even_when_no_files_are_readable
    cli = Sandcrawler::CLI.new
    manifest = { files: [], warnings: [{ code: "DIRECTORY_DAMAGED", detail: "erased" }] }
    assert_equal 4, cli.send(:result_code, manifest)
    manifest[:warnings] = [{ code: "DUPLICATE_ENTRY", detail: "same directory name" }]
    assert_equal 4, cli.send(:result_code, manifest)
  end

  def test_carving_uses_data_cluster_alignment
    fixture = build_fat
    fixture[:bytes].setbyte(13, 2)
    fixture[:bytes][fixture[:entry_offset] + 28, 4] = [1024].pack("V")
    content = "puts 'hello'\n".ljust(1024, " ")
    fixture[:bytes][fixture[:first] * 512, 1024] = content
    Dir.mktmpdir do |dir|
      source = File.join(dir, "image.bin")
      File.binwrite(source, fixture[:bytes])
      code, json, = run_cli("extract", source, "--carve", "--json", "-o", File.join(dir, "out"))
      assert_equal 4, code
      carved = JSON.parse(json)["files"].select { |file| file["output"].start_with?("carved/") }
      assert_equal 1, carved.size
      assert_equal Digest::SHA256.hexdigest(content), carved.first["sha256"]
    end
  end

  def test_auto_outputs_one_json_document_and_always_reminds_about_dump
    Dir.mktmpdir do |dir|
      tool = Object.new
      tool.define_singleton_method(:dump) do |out, **_options|
        FileUtils.mkdir_p(out)
        File.binwrite(File.join(out, "dump.bin"), "puts 1\n".ljust(4096, " "))
        { result: { unstable_blocks: [] } }
      end
      Sandcrawler::Acquisition::Picotool.stub(:new, tool) do
        code, json, error = run_cli("auto", "--json", "--carve", "-o", dir, input: "a\n")
        assert_equal 4, code
        assert_equal "sandcrawler", JSON.parse(json)["tool"]
        assert_includes error, "Keep dump.bin"
      end
      unstable_tool = Object.new
      unstable_tool.define_singleton_method(:dump) { |*, **| { result: { unstable_blocks: [0] } } }
      Sandcrawler::Acquisition::Picotool.stub(:new, unstable_tool) do
        code, json, error = run_cli("auto", "--json", "-o", File.join(dir, "unstable"), input: "a\n")
        assert_equal 5, code
        assert_equal [0], JSON.parse(json).dig("result", "unstable_blocks")
        assert_includes error, "Keep dump.bin"
      end
    end
  end

  def test_auto_rejects_nonempty_output_before_acquisition
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "keep"), "original")
      code, = run_cli("auto", "-o", dir, input: "a\n")
      assert_equal 1, code
      refute Dir.exist?(File.join(dir, "acquisition"))
    end
  end

  def test_fatal_read_failure_still_finalizes_recovered_files_manifest
    fixture = build_fat
    volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
    entry = volume.each_entry.first
    volume.define_singleton_method(:each_entry) do |&block|
      next enum_for(:each_entry) unless block

      block.call(entry)
      raise IOError, "image disappeared"
    end
    Dir.mktmpdir do |dir|
      path = File.join(dir, "source.bin")
      File.binwrite(path, fixture[:bytes])
      Sandcrawler::FAT::Volume.stub(:new, volume) do
        code, = run_cli("extract", path, "-o", File.join(dir, "out"))
        assert_equal 1, code
        manifest = JSON.parse(File.read(File.join(dir, "out", "manifest.json")))
        assert_equal 1, manifest["files"].size
        assert_equal "EXTRACTION_FAILED", manifest["warnings"].last["code"]
      end
    end
  end

  def test_source_modified_during_extraction_is_an_integrity_failure
    fixture = build_fat
    Dir.mktmpdir do |dir|
      path = File.join(dir, "source.bin")
      File.binwrite(path, fixture[:bytes])
      volume = Sandcrawler::FAT::Volume.new(source_for(fixture[:bytes]))
      original_read = volume.method(:read)
      volume.define_singleton_method(:read) do |entry|
        result = original_read.call(entry)
        File.open(path, "r+b") { |file| file.write("changed") }
        result
      end
      Sandcrawler::FAT::Volume.stub(:new, volume) do
        code, = run_cli("extract", path, "-o", File.join(dir, "out"))
        assert_equal 5, code
        manifest = JSON.parse(File.read(File.join(dir, "out", "manifest.json")))
        assert_equal 1, manifest["files"].size
        assert(manifest["warnings"].any? { |warning| warning["code"] == "SOURCE_CHANGED" })
      end
    end
  end

  def test_serial_port_selection_rejects_trailing_garbage
    cli = Sandcrawler::CLI.new(stdin: StringIO.new("1garbage\n"), stderr: StringIO.new)
    Sandcrawler::Acquisition::SerialShell.stub(:ports, ["COM1"]) do
      assert_raises(Sandcrawler::UsageError) { cli.send(:select_port) }
    end
  end

  def test_console_listing_escapes_control_characters_but_json_preserves_names
    fixture = build_fat
    short = fixture[:bytes][fixture[:entry_offset], 32]
    name = "bad\e[31m\nname.rb"
    records = lfn_entries(name, short[0, 11]) + short
    fixture[:bytes][fixture[:root], records.bytesize] = records
    Dir.mktmpdir do |dir|
      path = File.join(dir, "source.bin")
      File.binwrite(path, fixture[:bytes])
      code, output, = run_cli("ls", path)
      assert_equal 0, code
      refute_includes output, "\e"
      assert_equal 1, output.lines.size
      assert_equal name, JSON.parse(run_cli("ls", path, "--json")[1]).first["original_name"]
    end
  end
end
