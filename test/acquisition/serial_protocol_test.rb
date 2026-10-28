# frozen_string_literal: true

require_relative "../test_helper"
require "minitest/mock"

class SerialProtocolTest < Minitest::Test
  def setup
    @shell = Sandcrawler::Acquisition::SerialShell.new(io: StringIO.new)
  end

  def test_extra_fields_and_unexpected_records_are_not_silently_accepted
    [[%w[DATA 0 61 extra], %w[END 1 97]], [%w[BOGUS], %w[END 0 0]]].each do |records|
      assert_raises(Sandcrawler::IntegrityError) { @shell.send(:decode_transfer, records) }
    end
  end

  def test_duplicate_sequence_and_data_after_end_are_rejected
    [[%w[DATA 0 61], %w[DATA 0 61], %w[END 2 194]],
     [%w[END 0 0], %w[DATA 0 61]]].each do |records|
      assert_raises(Sandcrawler::IntegrityError) { @shell.send(:decode_transfer, records) }
    end
  end

  def test_directory_listing_requires_count_and_checksum
    record = ["LIST", "F", "app.rb".unpack1("H*")]
    assert_raises(Sandcrawler::IntegrityError) { @shell.send(:decode_listing, [record]) }
    assert_raises(Sandcrawler::IntegrityError) do
      @shell.send(:decode_listing, [record, %w[LISTEND 2 0]])
    end
  end

  def test_protocol_rejects_records_for_another_response_type
    io = StringIO.new
    shell = Sandcrawler::Acquisition::SerialShell.new(io: io)
    read = lambda do |_deadline|
      marker = io.string[/@@SANDCRAWLER\|[a-f0-9]+\|/]
      "#{marker}DATA|0|61\n"
    end
    shell.stub(:read_line, read) do
      assert_raises(Sandcrawler::IntegrityError) { shell.send(:request, expected: "CAP") { "nil" } }
    end
  end

  def test_response_budget_limits_a_peer_that_never_sends_done
    io = StringIO.new
    shell = Sandcrawler::Acquisition::SerialShell.new(io: io)
    read = lambda do |_deadline|
      marker = io.string[/@@SANDCRAWLER\|[a-f0-9]+\|/]
      "#{marker}DATA|0|#{'61' * 256}\n"
    end
    shell.stub(:read_line, read) do
      assert_raises(Sandcrawler::IntegrityError) { shell.send(:request, expected: "DATA") { "nil" } }
    end
  end
end
