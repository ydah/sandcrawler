# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "minitest/mock"

class MountedVolumeTest < Minitest::Test
  def test_copy_preserves_tree_hidden_files_timestamps_and_hashes
    Dir.mktmpdir do |tmp|
      source = File.join(tmp, "source")
      FileUtils.mkdir_p(File.join(source, "home"))
      File.write(File.join(source, "home", "app.rb"), "puts :hello\n")
      File.write(File.join(source, ".hidden"), "secret")
      File.utime(Time.at(1_700_000_000), Time.at(1_700_000_000), File.join(source, "home", "app.rb"))
      out = File.join(tmp, "out")
      result = Sandcrawler::Acquisition::MountedVolume.new(source).copy(out)
      assert_equal "puts :hello\n", File.read(File.join(out, "files", "home", "app.rb"))
      assert_equal "secret", File.read(File.join(out, "files", ".hidden"))
      assert_equal 1_700_000_000, File.mtime(File.join(out, "files", "home", "app.rb")).to_i
      assert(result[:warnings].any? { |w| w[:code] == "MOUNT_WRITE_RISK" })
    end
  end

  def test_rejects_output_inside_source
    Dir.mktmpdir do |tmp|
      assert_raises(Sandcrawler::SafetyError) do
        Sandcrawler::Acquisition::MountedVolume.new(tmp).copy(File.join(tmp, "out"))
      end
    end
  end

  def test_does_not_follow_symlinks
    skip "Creating symlinks may require privileges on Windows" if Gem.win_platform?
    Dir.mktmpdir do |tmp|
      source = File.join(tmp, "source")
      Dir.mkdir(source)
      File.write(File.join(tmp, "secret"), "secret")
      File.symlink(File.join(tmp, "secret"), File.join(source, "link"))
      File.symlink(source, File.join(source, "loop"))
      out = File.join(tmp, "out")
      result = Sandcrawler::Acquisition::MountedVolume.new(source).copy(out)
      refute File.exist?(File.join(out, "files", "link"))
      assert(result[:warnings].any? { |w| w[:code] == "SYMLINK_SKIPPED" })
    end
  end

  def test_mount_path_with_glob_characters_is_literal
    Dir.mktmpdir do |tmp|
      source = File.join(tmp, "rescue[1]")
      Dir.mkdir(source)
      File.write(File.join(source, "app.rb"), "puts 1")
      out = File.join(tmp, "out")
      result = Sandcrawler::Acquisition::MountedVolume.new(source).copy(out)
      assert_equal 1, result[:files].size
      assert_equal "puts 1", File.read(File.join(out, "files", "app.rb"))
    end
  end

  def test_replaced_file_symlink_is_not_followed
    skip "Symlink creation requires Windows privileges" if Gem.win_platform?
    Dir.mktmpdir do |tmp|
      source = File.join(tmp, "source")
      Dir.mkdir(source)
      path = File.join(source, "app.rb")
      secret = File.join(tmp, "secret")
      File.write(path, "original")
      File.write(secret, "private")
      path = File.realpath(path)
      original_open = File.method(:open)
      open_file = lambda do |name, *args, **options, &block|
        if name == path
          File.unlink(path)
          File.symlink(secret, path)
        end
        original_open.call(name, *args, **options, &block)
      end
      result = File.stub(:open, open_file) do
        Sandcrawler::Acquisition::MountedVolume.new(source).copy(File.join(tmp, "out"))
      end
      refute_equal "ok", result[:files].first[:status]
      assert(result[:warnings].any? { |warning| warning[:code] == "COPY_FAILED" })
    end
  end

  def test_source_rewritten_during_copy_is_reported_as_changed
    Dir.mktmpdir do |tmp|
      source = File.join(tmp, "source")
      Dir.mkdir(source)
      path = File.join(source, "app.rb")
      File.write(path, "original")
      File.utime(Time.at(1_600_000_000), Time.at(1_600_000_000), path)
      original_copy = IO.method(:copy_stream)
      copying = lambda do |input, output|
        size = original_copy.call(input, output)
        File.write(path, "modified")
        size
      end
      result = IO.stub(:copy_stream, copying) do
        Sandcrawler::Acquisition::MountedVolume.new(source).copy(File.join(tmp, "out"))
      end
      assert_equal "read_error", result[:files].first[:status]
      assert_equal 8, result[:files].first[:expected_size]
      assert(result[:warnings].any? { |warning| warning[:code] == "SOURCE_CHANGED" })
    end
  end

  def test_regular_file_replaced_while_opening_is_rejected
    Dir.mktmpdir do |tmp|
      source = File.join(tmp, "source")
      Dir.mkdir(source)
      path = File.join(source, "app.rb")
      replacement = File.join(tmp, "replacement")
      File.write(path, "original")
      File.write(replacement, "private!")
      [path, replacement].each { |name| File.utime(Time.at(1_600_000_000), Time.at(1_600_000_000), name) }
      path = File.realpath(path)
      original_open = File.method(:open)
      open_file = lambda do |name, *args, **options, &block|
        if name == path
          File.rename(path, File.join(tmp, "saved"))
          File.rename(replacement, path)
        end
        original_open.call(name, *args, **options, &block)
      end
      out = File.join(tmp, "out")
      result = File.stub(:open, open_file) { Sandcrawler::Acquisition::MountedVolume.new(source).copy(out) }
      record = result[:files].first
      assert_equal "read_error", record[:status]
      assert_empty File.binread(File.join(out, record[:output]))
      assert(result[:warnings].any? { |warning| warning[:code] == "COPY_FAILED" })
    end
  end

  def test_changed_source_device_with_the_same_inode_is_rejected
    Dir.mktmpdir do |tmp|
      source = File.join(tmp, "source")
      Dir.mkdir(source)
      path = File.join(source, "app.rb")
      File.write(path, "original")
      path = File.realpath(path)
      original_lstat = File.method(:lstat)
      checks = 0
      lstat = lambda do |name|
        stat = original_lstat.call(name)
        if name == path
          checks += 1
          device = stat.dev
          stat.define_singleton_method(:dev) { device + 1 } if checks > 1
        end
        stat
      end
      result = File.stub(:lstat, lstat) do
        Sandcrawler::Acquisition::MountedVolume.new(source).copy(File.join(tmp, "out"))
      end
      assert_equal "read_error", result[:files].first[:status]
      assert(result[:warnings].any? { |warning| warning[:code] == "COPY_FAILED" })
    end
  end

  def test_directory_replaced_by_symlink_does_not_expose_its_children
    skip "Symlink creation requires Windows privileges" if Gem.win_platform?
    Dir.mktmpdir do |tmp|
      source = File.join(tmp, "source")
      home = File.join(source, "home")
      private_dir = File.join(tmp, "private")
      FileUtils.mkdir_p([home, private_dir])
      File.write(File.join(home, "app.rb"), "original")
      File.write(File.join(private_dir, "app.rb"), "private")
      home = File.realpath(home)
      original_lstat = File.method(:lstat)
      changed = false
      lstat = lambda do |path|
        if path == home && !changed
          changed = true
          File.rename(home, File.join(tmp, "saved"))
          File.symlink(private_dir, home)
        end
        original_lstat.call(path)
      end
      result = File.stub(:lstat, lstat) do
        Sandcrawler::Acquisition::MountedVolume.new(source).copy(File.join(tmp, "out"))
      end
      assert_empty result[:files]
      assert(result[:warnings].any? { |warning| warning[:code] == "SYMLINK_SKIPPED" })
    end
  end
end
