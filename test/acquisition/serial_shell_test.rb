# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "minitest/mock"

class SerialShellTest < Minitest::Test
  def setup
    assert defined?(Sandcrawler::Acquisition::SerialShell), "Serial acquisition is implemented"
  end

  class PipeAdapter
    def initialize(reader, writer)
      @reader = reader
      @writer = writer
    end

    def write(data)
      @writer.write(data)
      @writer.flush
    end

    def read_nonblock(size, exception: false)
      @reader.read_nonblock(size, exception: exception)
    end

    def to_io
      @reader
    end
  end

  def with_device(bad_first: false, bad_always: false, omit_end: false, fallback: false, drop_list: false,
                  omit_done: false)
    host_read, device_write = IO.pipe
    device_read, host_write = IO.pipe
    commands = []
    attempts = 0
    device = Thread.new do
      device_read.each_line do |line|
        commands << line
        if line.include?("\x03")
          device_write.write("r2p2> ")
          device_write.flush
          next
        end
        if line.strip == "irb"
          device_write.write("irb> ")
          device_write.flush
          next
        end
        next unless (token = line[/@@SANDCRAWLER\|([a-f0-9]+)\|/, 1])

        marker = "@@SANDCRAWLER|#{token}|"
        device_write.puts(line) # Echo cannot count as a response.
        device_write.puts("@@SANDCRAWLER|stale-token|ERROR|ignore this old response")
        case line
        when /\|CAP\|/
          mode = fallback ? "open|stat|each_byte" : "entries|directory|bytes"
          device_write.puts("\e[32m#{marker}CAP|#{mode}\e[0m")
        when /\|LIST\|/
          record = "F|#{'app.rb'.unpack1('H*')}"
          device_write.puts("#{marker}LIST|#{record}") unless drop_list
          device_write.puts("#{marker}LISTEND|1|#{record.bytes.sum % 65_536}")
        when /\|READCAP\|/
          device_write.puts("#{marker}READCAP|#{fallback ? 'getc' : 'read'}")
        when /\|DATA\|/
          attempts += 1
          body = "puts :hello\n"
          device_write.puts("#{marker}DATA|0|#{body.unpack1('H*')}")
          checksum = body.bytes.sum % 65_536
          checksum += 1 if bad_always || (bad_first && attempts == 1)
          device_write.puts("#{marker}END|#{body.bytesize}|#{checksum}") unless omit_end
        end
        device_write.puts("#{marker}DONE") unless omit_done
        device_write.flush
      end
    rescue IOError, Errno::EPIPE
      nil
    end
    yield PipeAdapter.new(host_read, host_write), commands, -> { attempts }
  ensure
    [host_read, device_write, device_read, host_write].compact.each { |io| io.close unless io.closed? }
    device&.join(1)
    device&.kill
  end

  def test_transfers_file_ignoring_echo_and_ansi_noise
    with_device do |io, commands, attempts|
      Dir.mktmpdir do |tmp|
        result = Sandcrawler::Acquisition::SerialShell.new(io: io, timeout: 1).copy(File.join(tmp, "out"))
        assert_equal "puts :hello\n", File.read(File.join(tmp, "out", "files", "app.rb"))
        assert_equal 1, attempts.call
        assert_equal "ok", result[:files].find { |file| file[:path] == "app.rb" }[:status]
        assert commands.any? { |line| line.strip == "exit" } || commands.last.include?("DATA")
        refute(commands.any? { |line| line.match?(/File\.(?:unlink|delete|write)/) })
      end
    end
  end

  def test_retries_checksum_mismatch
    with_device(bad_first: true) do |io, _commands, attempts|
      Dir.mktmpdir do |tmp|
        Sandcrawler::Acquisition::SerialShell.new(io: io, timeout: 1).copy(File.join(tmp, "out"))
        assert_equal 2, attempts.call
        assert_equal "puts :hello\n", File.read(File.join(tmp, "out", "files", "app.rb"))
      end
    end
  end

  def test_retry_exhaustion_marks_file_failed_and_finishes_manifest
    with_device(bad_always: true) do |io, _commands, attempts|
      Dir.mktmpdir do |tmp|
        result = Sandcrawler::Acquisition::SerialShell.new(io: io, timeout: 1).copy(File.join(tmp, "out"))
        assert_equal 3, attempts.call
        assert_equal "transfer_error", result[:files].find { |file| file[:path] == "app.rb" }[:status]
        assert File.file?(File.join(tmp, "out", "manifest.json"))
      end
    end
  end

  def test_missing_end_is_not_accepted
    with_device(omit_end: true) do |io, _commands, _attempts|
      Dir.mktmpdir do |tmp|
        result = Sandcrawler::Acquisition::SerialShell.new(io: io, timeout: 1).copy(File.join(tmp, "out"))
        assert_equal "transfer_error", result[:files].find { |file| file[:path] == "app.rb" }[:status]
      end
    end
  end

  def test_fallback_uses_probed_api_and_escapes_paths
    with_device(fallback: true) do |io, commands, _attempts|
      Dir.mktmpdir do |tmp|
        Sandcrawler::Acquisition::SerialShell.new(io: io, timeout: 1).copy(File.join(tmp, "out"),
                                                                           root: '/home/";raise "bad')
        transfer = commands.find { |line| line.include?("|DATA|") }
        assert_includes transfer, ".getc"
        assert_includes transfer, ".each_byte"
        assert_includes transfer, '/home/\\";raise \\"bad'.sub('\\\\"', '\\"')
      end
    end
  end

  def test_windows_ports_are_read_from_platform_inventory
    status = Object.new
    def status.success?
      true
    end
    Gem.stub(:win_platform?, true) do
      Open3.stub(:capture3, ["COM7\r\nCOM2\r\n", "", status]) do
        assert_equal %w[COM2 COM7], Sandcrawler::Acquisition::SerialShell.ports
      end
    end
  end

  def test_lost_directory_response_is_not_an_empty_success
    with_device(drop_list: true) do |io, _commands, attempts|
      Dir.mktmpdir do |tmp|
        result = Sandcrawler::Acquisition::SerialShell.new(io: io, timeout: 1).copy(File.join(tmp, "out"))
        assert_equal 0, attempts.call
        assert(result[:warnings].any? { |warning| warning[:code] == "LIST_FAILED" })
      end
    end
  end

  def test_missing_done_times_out_and_writes_failure_manifest
    with_device(omit_done: true) do |io, _commands, _attempts|
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "out")
        assert_raises(Sandcrawler::IntegrityError) do
          Sandcrawler::Acquisition::SerialShell.new(io: io, timeout: 0.05).copy(out)
        end
        manifest = JSON.parse(File.read(File.join(out, "manifest.json")))
        assert(manifest["warnings"].any? { |warning| warning["code"] == "SERIAL_FAILED" })
      end
    end
  end
end
