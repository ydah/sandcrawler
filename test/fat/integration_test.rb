# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fat_builder"

class FatIntegrationTest < Minitest::Test
  include FatBuilder

  def run_cli(*args)
    output = StringIO.new
    errors = StringIO.new
    code = Sandcrawler::CLI.new(stdout: output, stderr: errors).run(args)
    [code, output.string, errors.string]
  end

  def test_boot_sector_recovery_using_reference_and_manual_geometry
    Dir.mktmpdir do |directory|
      fixture = build_fat(bps: 4096, lfn: true)
      reference = File.join(directory, "ref.bin")
      damaged = File.join(directory, "damaged.bin")
      File.binwrite(reference, ("\xFF".b * 4096) + fixture[:bytes])
      fixture[:bytes][0, 4096] = "\xFF".b * 4096
      File.binwrite(damaged, ("\xFF".b * 4096) + fixture[:bytes])
      configurations = [["--reference-image", reference],
                        ["--geometry", "bps=4096,spc=1,rsvd=1,fats=2,fatsz=1,root=32,offset=4096"]]
      configurations.each_with_index do |options, index|
        out = File.join(directory, "out#{index}")
        code, _, errors = run_cli("extract", damaged, "-o", out, *options)
        assert_equal 0, code, errors
        assert_equal "puts 'hello'", File.binread(File.join(out, "files", "日本語のファイル名.rb"))
        manifest = JSON.parse(File.read(File.join(out, "manifest.json")))
        assert_equal 4096, manifest.dig("volume", "offset")
        assert_equal Digest::SHA256.file(damaged).hexdigest, manifest.dig("source", "sha256")
        refute_empty manifest["warnings"]
      end
    end
  end

  def test_corrupt_chain_is_partial_and_fat_copy_repair_is_normal
    Dir.mktmpdir do |directory|
      fixture = build_fat
      image = File.join(directory, "damaged.bin")
      fixture[:bytes][fixture[:entry_offset] + 28, 4] = [1024].pack("V")
      change_fat(fixture, 2, 2)
      File.binwrite(image, fixture[:bytes])
      out = File.join(directory, "out")
      code, _, errors = run_cli("extract", image, "-o", out)
      assert_equal 4, code, errors
      assert_path_exists File.join(out, "files", "app.rb.partial")
      manifest = JSON.parse(File.read(File.join(out, "manifest.json")))
      assert_equal "chain_error", manifest["files"].first["status"]
      fixture = build_fat
      fixture[:bytes][512, 512] = "\xFF".b * 512
      File.binwrite(image, fixture[:bytes])
      out = File.join(directory, "repaired")
      code, _, errors = run_cli("extract", image, "-o", out)
      assert_equal 0, code, errors
      assert_equal "puts 'hello'", File.binread(File.join(out, "files", "app.rb"))
    end
  end

  def test_no_fat_carving_and_deleted_output
    Dir.mktmpdir do |directory|
      image = File.join(directory, "text.bin")
      File.binwrite(image, "puts 'hello'\n".ljust(4096, " "))
      out = File.join(directory, "carved")
      code, _, errors = run_cli("extract", image, "-o", out, "--carve")
      assert_equal 4, code, errors
      assert_path_exists File.join(out, "carved", "00000000.txt")
      fixture = build_fat(deleted: true)
      File.binwrite(image, fixture[:bytes])
      out = File.join(directory, "deleted")
      code, _, errors = run_cli("extract", image, "-o", out, "--deleted")
      assert_equal 4, code, errors
      assert_equal "puts 'hello'", File.binread(File.join(out, "deleted", "_pp.rb"))
    end
  end
end
