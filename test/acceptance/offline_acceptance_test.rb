# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/uf2_builder"

class OfflineAcceptanceTest < Minitest::Test
  include Uf2Builder

  FIXTURES = File.expand_path("../fixtures/generated", __dir__)

  def setup
    unless File.file?(File.join(FIXTURES, "complete"))
      flunk "Acceptance fixtures are required" if ENV["REQUIRE_FIXTURES"] == "1"
      skip "Run rake fixtures for independent CLI acceptance tests"
    end
    @tmp = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp
  end

  def test_all_generated_filesystems_extract_to_the_independent_expected_tree
    %w[fat12_512 fat12_4096 fat16_512 fat32_512].each do |name|
      output, manifest = extract(fixture("#{name}.img"), name)
      assert_tree_matches(fixture("#{name}.expected"), output, manifest)
      assert_empty manifest.fetch("warnings"), name
      assert manifest.fetch("files").all? { |entry| entry.fetch("status") == "ok" }, name
    end
  end

  def test_raw_flash_and_unordered_uf2_produce_the_same_tree_and_geometry
    raw = fixture("flash_fat12_4096.bin")
    bytes = File.binread(raw)
    uf2 = File.join(@tmp, "flash.uf2")
    count = bytes.bytesize / 256
    File.open(uf2, "wb") do |file|
      (count - 1).downto(0) do |number|
        file.write(uf2_block(bytes.byteslice(number * 256, 256), offset: number * 256, number: number, total: count))
      end
    end
    raw_output, raw_manifest = extract(raw, "raw")
    uf2_output, uf2_manifest = extract(uf2, "uf2")
    [raw_output, uf2_output].each do |output|
      assert_equal tree(fixture("fat12_4096.expected")), tree(File.join(output, "files"))
    end
    assert_equal raw_manifest.fetch("volume"), uf2_manifest.fetch("volume")
    assert_equal 0x100000, uf2_manifest.dig("volume", "offset")
    assert_equal bytes.bytesize, uf2_manifest.dig("source", "image_size")
    assert_equal Digest::SHA256.file(uf2).hexdigest, uf2_manifest.dig("source", "sha256")
    assert_equal Digest::SHA256.hexdigest(bytes), Digest::SHA256.file(raw).hexdigest
  end

  def test_generated_erased_fat_and_boot_sector_are_recovered_without_content_changes
    cases = [
      ["fat1_erased.bin", [], "FAT_MISMATCH"],
      ["boot_erased.bin", ["--reference-image", fixture("fat12_4096.img")], "REFERENCE_GEOMETRY"]
    ]
    cases.each_with_index do |(input, options, warning), index|
      output, manifest = extract(fixture(input), "repaired#{index}", *options)
      assert_tree_matches(fixture("fat12_4096.expected"), output, manifest)
      assert_includes manifest.fetch("warnings").map { |item| item.fetch("code") }, warning
      assert(manifest.fetch("files").all? { |entry| entry.fetch("status") == "ok" })
    end
  end

  def test_generated_deleted_file_recovers_exact_bytes_with_explicit_uncertainty
    output, manifest = extract(fixture("fat12_4096.img"), "deleted", "--deleted", status: 4)
    deleted = manifest.fetch("files").select { |entry| entry.fetch("output").start_with?("deleted/") }
    assert_equal 1, deleted.size
    assert_equal "recovered", deleted.first.fetch("status")
    assert_equal File.binread(fixture("fat12_4096.expected/home/app.rb")),
                 File.binread(File.join(output, deleted.first.fetch("output")))
    assert_includes deleted.first.fetch("warnings").map { |item| item.fetch("code") }, "DELETED_GUESS"
    assert_equal tree(fixture("fat12_4096.expected")), tree(File.join(output, "files"))
  end

  def test_generated_erased_directory_yields_exact_orphan_prefixes_and_keeps_other_files
    output, manifest = extract(fixture("directory_erased.bin"), "orphans", "--orphans", status: 4)
    survivors = tree(fixture("fat12_4096.expected")).reject { |path, _| path.start_with?("home/") }
    assert_equal survivors, tree(File.join(output, "files"))
    orphans = manifest.fetch("files").select { |entry| entry.fetch("output").start_with?("lost+found/") }
    assert_equal 2, orphans.size
    original_contents = Dir[fixture("fat12_4096.expected/home/*")].map { |path| File.binread(path) }
    recovered_contents = orphans.map { |entry| File.binread(File.join(output, entry.fetch("output"))) }
    original_contents.each do |original|
      assert recovered_contents.any? { |data| data.start_with?(original) }, "Missing original orphan content"
    end
    assert(orphans.all? { |entry| entry.fetch("status") == "recovered" })
    assert_includes manifest.fetch("warnings").map { |item| item.fetch("code") }, "DIRECTORY_DAMAGED"
  end

  def test_generated_chain_loop_is_partial_and_does_not_hide_intact_siblings
    output, manifest = extract(fixture("chain_loop.bin"), "loop", status: 4)
    blob = manifest.fetch("files").find { |entry| entry.fetch("path") == "lib/blob.bin" }
    assert_equal "chain_error", blob.fetch("status")
    assert_equal "files/lib/blob.bin.partial", blob.fetch("output")
    original = File.binread(fixture("fat12_4096.expected/lib/blob.bin"))
    assert_equal original.byteslice(0, 4096), File.binread(File.join(output, blob.fetch("output")))
    intact = tree(fixture("fat12_4096.expected")).except("lib/blob.bin")
    actual = tree(File.join(output, "files")).except("lib/blob.bin.partial")
    assert_equal intact, actual
  end

  private

  def fixture(name)
    File.join(FIXTURES, name)
  end

  def extract(input, name, *options, status: 0)
    output = File.join(@tmp, name)
    stdout = StringIO.new
    stderr = StringIO.new
    hash_before = Digest::SHA256.file(input).hexdigest
    code = Sandcrawler::CLI.new(stdout: stdout, stderr: stderr).run(
      ["extract", input, "-o", output, "--json", *options]
    )
    assert_equal status, code, stderr.string
    manifest = JSON.parse(stdout.string)
    assert_equal manifest, JSON.parse(File.read(File.join(output, "manifest.json")))
    assert_equal hash_before, manifest.dig("source", "sha256")
    assert_equal hash_before, Digest::SHA256.file(input).hexdigest, "Input image changed during extraction"
    manifest.fetch("files").each do |entry|
      path = File.join(output, entry.fetch("output"))
      assert_equal Digest::SHA256.file(path).hexdigest, entry.fetch("sha256")
      assert_equal File.size(path), entry.fetch("size")
      assert_equal Time.iso8601(entry.fetch("mtime")), File.mtime(path) if entry["mtime"]
    end
    [output, manifest]
  end

  def tree(root)
    Dir.glob("**/*", base: root).sort.to_h do |path|
      full_path = File.join(root, path)
      [path, File.directory?(full_path) ? :directory : Digest::SHA256.file(full_path).hexdigest]
    end
  end

  def assert_tree_matches(expected, output, manifest)
    assert_equal tree(expected), tree(File.join(output, "files"))
    actual_paths = manifest.fetch("files").map { |entry| entry.fetch("path") }.sort
    expected_paths = tree(expected).reject { |_, value| value == :directory }.keys.sort
    assert_equal expected_paths, actual_paths
  end
end
