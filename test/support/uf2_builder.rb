# frozen_string_literal: true

module Uf2Builder
  def uf2_block(data, offset: 0, number: 0, total: 1, flags: 0)
    header = [0x0A324655, 0x9E5D5157, flags, 0x10000000 + offset, data.bytesize, number, total, 0].pack("V*")
    header + data.b.ljust(476, "\0") + [0x0AB16F30].pack("V")
  end
end
