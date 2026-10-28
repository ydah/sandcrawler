# frozen_string_literal: true

module Corruptor
  def erase_block(bytes, offset, size: 4096)
    bytes.dup.tap { |copy| copy[offset, size] = "\xFF".b * size }
  end

  def alter_entry(bytes, offset, field_offset, packed_value)
    bytes.dup.tap { |copy| copy[offset + field_offset, packed_value.bytesize] = packed_value }
  end
end
