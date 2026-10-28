# frozen_string_literal: true

require_relative "../test_helper"
require "minitest/mock"

class SerialTemplatesTest < Minitest::Test
  def test_real_templates_round_trip_binary_and_empty_files_with_both_readers
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "quoted'日本語.rb")
      ["".b, (0..255).to_a.pack("C*") * 3].each do |expected|
        File.binwrite(path, expected)
        %w[read getc].each do |reader|
          %w[bytes each_byte].each do |bytes|
            code = Sandcrawler::Acquisition::SerialTemplates.transfer(path, { bytes: bytes }, reader, "marker|")
            stdout = evaluate_template(code)
            records = stdout.lines.map(&:strip).map { |line| line.split("|") }
            chunks = records.select { |record| record[1] == "DATA" }
            assert_equal expected, chunks.map { |record| [record[3]].pack("H*") }.join.b
            assert_equal ["marker", "END", expected.bytesize.to_s, (expected.bytes.sum % 65_536).to_s], records.last
          end
        end
      end
    end
  end

  def test_real_directory_templates_handle_japanese_names_and_directory_fallback
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "日本語.rb"), "")
      Dir.mkdir(File.join(tmp, "home"))
      [{ list: "entries", directory: "directory", bytes: "bytes" },
       { list: "open", directory: "stat", bytes: "each_byte" }].each do |capabilities|
        code = Sandcrawler::Acquisition::SerialTemplates.listing(tmp, capabilities, "marker|")
        stdout = evaluate_template(code)
        records = stdout.lines.map(&:strip)
        assert_includes records, "marker|LIST|F|#{'日本語.rb'.unpack1('H*')}"
        assert_includes records, "marker|LIST|D|#{'home'.unpack1('H*')}"
        assert_equal 3, records.length
        checksum = records.first(2).sum { |record| record.delete_prefix("marker|LIST|").bytes.sum } % 65_536
        assert_equal "marker|LISTEND|2|#{checksum}", records.last
      end
    end
  end

  private

  def evaluate_template(code)
    open_file = File.method(:open)
    # The Pico has byte-based paths and reads, even when the host is Windows.
    device_open = lambda do |path, mode, &block|
      raise "Device template must only read" unless mode == "r"

      open_file.call(path.dup.force_encoding(Encoding::UTF_8), "rb", &block)
    end
    File.stub(:open, device_open) do
      capture_io { eval(code, binding, __FILE__, __LINE__) }.first # rubocop:disable Security/Eval
    end
  end
end
