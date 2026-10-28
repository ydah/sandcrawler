# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "json"
require "minitest/mock"
require "rbconfig"

class PicotoolTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @old_mode = ENV.fetch("SANDCRAWLER_FAKE_MODE", nil)
    ENV["SANDCRAWLER_FAKE_STATE"] = File.join(@tmp, "state")
    assert defined?(Sandcrawler::Acquisition::Picotool), "Picotool acquisition is implemented"
    fake = File.expand_path("../support/fake_picotool", __dir__)
    if Gem.win_platform?
      launcher = File.join(@tmp, "fake_picotool.cmd")
      ruby = RbConfig.ruby.tr("/", "\\").gsub("%", "%%")
      script = fake.tr("/", "\\").gsub("%", "%%")
      File.binwrite(launcher, "@echo off\r\n\"#{ruby}\" \"#{script}\" %*\r\n")
      fake = launcher
    end
    @tool = Sandcrawler::Acquisition::Picotool.new(executable: fake)
  end

  def teardown
    ENV["SANDCRAWLER_FAKE_MODE"] = @old_mode
    ENV.delete("SANDCRAWLER_FAKE_STATE")
    Dir.glob(File.join(@tmp, "**", "*.bin")).each { |path| File.chmod(0o600, path) }
    FileUtils.remove_entry(@tmp)
  end

  def test_rejects_writing_commands_and_reboot_flags
    %w[load erase reboot otp config].each do |command|
      assert_raises(Sandcrawler::SafetyError) { @tool.run(command) }
    end
    assert_raises(Sandcrawler::SafetyError) { @tool.run("info", "-f") }
    assert_raises(Sandcrawler::SafetyError) { @tool.run("save", "--force") }
    assert_raises(Sandcrawler::SafetyError) { @tool.run("save", "-r", nil, "0x1000", "-v", "x", "-t", "bin") }
  end

  def test_dump_records_matching_passes_and_read_only_image
    result = @tool.dump(File.join(@tmp, "out"))
    assert_equal 2, result[:passes].size
    assert_equal 8192, result[:device][:flash_size]
    assert_equal "RP2040", result[:device][:chip]
    assert_empty result[:result][:unstable_blocks]
    image = File.join(@tmp, "out", result[:result][:file])
    assert_equal "A" * 8192, File.binread(image)
    assert_equal Digest::SHA256.file(image).hexdigest, result[:result][:sha256]
    assert_equal 0, File.stat(image).mode & 0o222 unless Gem.win_platform?
    assert File.file?(File.join(@tmp, "out", "manifest.json"))
  end

  def test_disagreement_adds_pass_and_uses_block_majority
    ENV["SANDCRAWLER_FAKE_MODE"] = "first_bad"
    result = @tool.dump(File.join(@tmp, "out"))
    assert_equal 3, result[:passes].size
    assert_empty result[:result][:unstable_blocks]
    assert_equal "A" * 8192, File.binread(File.join(@tmp, "out", "dump.bin"))
  end

  def test_no_majority_is_recorded_and_all_evidence_is_kept
    ENV["SANDCRAWLER_FAKE_MODE"] = "unstable"
    result = @tool.dump(File.join(@tmp, "out"))
    assert_equal [0, 4096], result[:result][:unstable_blocks]
    assert_equal 3, Dir.glob(File.join(@tmp, "out", "pass*.bin")).size
  end

  def test_save_all_failure_retries_explicit_flash_range
    ENV["SANDCRAWLER_FAKE_MODE"] = "range"
    result = @tool.dump(File.join(@tmp, "out"))
    assert_empty result[:result][:unstable_blocks]
    calls = File.read("#{ENV.fetch('SANDCRAWLER_FAKE_STATE')}.calls")
    assert_includes calls, "-r 0x10000000 0x10002000"
  end

  def test_short_dump_is_not_accepted
    ENV["SANDCRAWLER_FAKE_MODE"] = "short"
    assert_raises(Sandcrawler::IntegrityError) { @tool.dump(File.join(@tmp, "out")) }
    assert File.file?(File.join(@tmp, "out", "manifest.json"))
  end

  def test_missing_device_has_specific_error
    ENV["SANDCRAWLER_FAKE_MODE"] = "missing"
    assert_raises(Sandcrawler::DeviceNotFoundError) { @tool.info }
  end

  def test_invalid_passes_does_not_create_output
    assert_raises(Sandcrawler::UsageError) { @tool.dump(File.join(@tmp, "out"), passes: 0) }
    assert_raises(Sandcrawler::UsageError) { @tool.dump(File.join(@tmp, "out"), passes: 1) }
    refute File.exist?(File.join(@tmp, "out"))
  end

  def test_output_write_failure_is_reported_as_integrity_error
    writer = Sandcrawler::Extractor.new(File.join(@tmp, "out"), source: {})
    writer.stub(:write, { status: "read_error", output: nil, path: "pass1.bin" }) do
      Sandcrawler::Extractor.stub(:new, writer) do
        assert_raises(Sandcrawler::IntegrityError) { @tool.dump(File.join(@tmp, "out")) }
      end
    end
  end

  def test_sidecar_write_failure_cannot_report_success
    out = File.join(@tmp, "out")
    writer = Sandcrawler::Extractor.new(out, source: {})
    original = writer.method(:write)
    failed_write = lambda do |**options|
      if options[:path] == "dump.json"
        { path: options[:path], status: "read_error", output: nil }
      else
        original.call(**options)
      end
    end
    writer.stub(:write, failed_write) do
      Sandcrawler::Extractor.stub(:new, writer) do
        assert_raises(Sandcrawler::IntegrityError) { @tool.dump(out) }
      end
    end
  end

  def test_failed_save_preserves_partial_bytes_before_range_retry
    ENV["SANDCRAWLER_FAKE_MODE"] = "partial_failure"
    out = File.join(@tmp, "out")
    assert_raises(Sandcrawler::Error) { @tool.dump(out) }
    manifest = JSON.parse(File.read(File.join(out, "manifest.json")))
    entries = manifest["files"].reject { |file| file["output"].nil? }
    assert_equal(%w[FIRST SECOND], entries.map { |file| File.binread(File.join(out, file["output"])) })
    assert(entries.all? { |entry| entry["status"] == "acquisition_error" })
  end

  def test_stuck_command_is_terminated_at_the_deadline
    File.write(File.join(@tmp, "version"), "sleep 60\n")
    Dir.chdir(@tmp) do
      assert_raises(Sandcrawler::IntegrityError) do
        Sandcrawler::Acquisition::Picotool.new(executable: RbConfig.ruby, timeout: 0.1).version
      end
    end
  end

  def test_changed_pass_length_is_an_integrity_error
    writer = Sandcrawler::Extractor.new(File.join(@tmp, "out"), source: {})
    File.binwrite(File.join(writer.out, "pass1.bin"), "short")
    records = [{ file: "pass1.bin", size: 8192 }]
    assert_raises(Sandcrawler::IntegrityError) { @tool.send(:combine, writer, records) }
  end

  def test_binary_device_metadata_is_preserved_without_breaking_dump_json
    ENV["SANDCRAWLER_FAKE_MODE"] = "invalid_info"
    out = File.join(@tmp, "out")
    result = @tool.dump(out)
    assert_equal "RP2040", result[:device][:chip]
    assert_equal 8192, result[:device][:flash_size]
    assert result[:picotool][:info].valid_encoding?
    assert result[:picotool][:info_hex].end_with?("6e616d653a20ff0a")
    assert_equal result[:picotool][:info_hex],
                 JSON.parse(File.read(File.join(out, "dump.json"))).dig("picotool", "info_hex")
    assert File.file?(File.join(out, "manifest.json"))
  end

  def test_binary_error_output_keeps_device_not_found_classification
    ENV["SANDCRAWLER_FAKE_MODE"] = "invalid_error"
    assert_raises(Sandcrawler::DeviceNotFoundError) { @tool.info }
  end

  def test_truncated_preserved_file_is_not_accepted
    record = { path: "pass1.bin", output: "pass1.bin.partial", status: "truncated" }
    assert_raises(Sandcrawler::IntegrityError) { @tool.send(:verify_output!, record) }
  end

  def test_command_output_is_bounded_before_the_command_deadline
    ENV["SANDCRAWLER_FAKE_MODE"] = "flood"
    executable = @tool.instance_variable_get(:@executable)
    error = assert_raises(Sandcrawler::IntegrityError) do
      Sandcrawler::Acquisition::Picotool.new(executable: executable, timeout: 2).version
    end
    assert_includes error.message, "output limit"
  end

  def test_host_read_error_keeps_manifest_for_existing_passes
    out = File.join(@tmp, "out")
    @tool.stub(:combine, ->(*) { raise IOError, "storage disconnected" }) do
      assert_raises(IOError) { @tool.dump(out) }
    end
    assert File.file?(File.join(out, "manifest.json"))
    manifest = JSON.parse(File.read(File.join(out, "manifest.json")))
    assert_equal 2, manifest["files"].size
    assert(manifest["warnings"].any? { |warning| warning["code"] == "DUMP_FAILED" })
  end
end
