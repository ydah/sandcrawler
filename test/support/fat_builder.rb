# frozen_string_literal: true

module FatBuilder
  def build_fat(bits: 12, bps: 512, deleted: false, lfn: false)
    clusters = { 12 => 32, 16 => 4090, 32 => 65_530 }.fetch(bits)
    reserved = bits == 32 ? 32 : 1
    root_entries = bits == 32 ? 0 : 32
    fat_sectors = ((((clusters + 2) * bits) + 7) / 8.0 / bps).ceil
    root_sectors = ((root_entries * 32) + bps - 1) / bps
    first = reserved + (fat_sectors * 2) + root_sectors
    total = first + clusters
    bytes = "\0".b * (total * bps)
    bytes[0, 3] = "\xEB\x3C\x90".b
    bytes[11, 2] = [bps].pack("v")
    bytes.setbyte(13, 1)
    bytes[14, 2] = [reserved].pack("v")
    bytes.setbyte(16, 2)
    bytes[17, 2] = [root_entries].pack("v")
    bytes[total < 65_536 ? 19 : 32, total < 65_536 ? 2 : 4] = [total].pack(total < 65_536 ? "v" : "V")
    bytes.setbyte(21, 0xF8)
    bytes[bits == 32 ? 36 : 22, bits == 32 ? 4 : 2] = [fat_sectors].pack(bits == 32 ? "V" : "v")
    bytes[44, 4] = [2].pack("V") if bits == 32
    bytes[bits == 32 ? 71 : 43, 11] = "R2P2       "
    bytes[510, 2] = "\x55\xAA".b
    fat = "\0".b * (fat_sectors * bps)
    set_fat(fat, 0, if bits == 12
                      0xFF8
                    else
                      bits == 16 ? 0xFFF8 : 0x0FFFFFF8
                    end, bits)
    set_fat(fat, 1, (1 << bits) - 1, bits)
    set_fat(fat, 2, (1 << bits) - 1, bits) if bits == 32
    file_cluster = bits == 32 ? 3 : 2
    set_fat(fat, file_cluster, (1 << bits) - 1, bits) unless deleted
    2.times { |i| bytes[(reserved + (i * fat_sectors)) * bps, fat.bytesize] = fat }
    root = bits == 32 ? first * bps : (reserved + (2 * fat_sectors)) * bps
    entry = short_entry("APP     RB ", file_cluster, 12)
    entry.setbyte(12, 0x18)
    records = lfn ? lfn_entries("日本語のファイル名.rb", entry[0, 11]) + entry : entry
    (0...records.bytesize).step(32) { |i| records.setbyte(i, 0xE5) } if deleted
    bytes[root, records.bytesize] = records
    bytes[(first + file_cluster - 2) * bps, 12] = "puts 'hello'"
    { bytes: bytes, bits: bits, bps: bps, reserved: reserved, fatsz: fat_sectors, root: root,
      first: first, cluster: file_cluster, total: total, entry_offset: root + records.bytesize - 32 }
  end

  def short_entry(name, cluster, size, attr: 0x20)
    entry = "\0".b * 32
    entry[0, 11] = name
    entry.setbyte(11, attr)
    entry[20, 2] = [cluster >> 16].pack("v")
    entry[26, 2] = [cluster & 0xFFFF].pack("v")
    entry[28, 4] = [size].pack("V")
    entry
  end

  def lfn_entries(name, short)
    checksum = short.bytes.reduce(0) { |sum, byte| (((sum & 1) << 7) + (sum >> 1) + byte) & 255 }
    units = name.encode("UTF-16LE").unpack("v*") + [0]
    units << 0xFFFF until (units.length % 13).zero?
    units.each_slice(13).with_index.map do |chunk, index|
      entry = "\0".b * 32
      entry.setbyte(0, index + 1 + (index == (units.length / 13) - 1 ? 0x40 : 0))
      entry.setbyte(11, 0x0F)
      entry.setbyte(13, checksum)
      packed = chunk.pack("v*")
      entry[1, 10] = packed[0, 10]
      entry[14, 12] = packed[10, 12]
      entry[28, 4] = packed[22, 4]
      entry
    end.reverse.join
  end

  def set_fat(bytes, cluster, value, bits)
    if bits == 12
      offset = cluster + (cluster / 2)
      word = bytes[offset, 2].unpack1("v")
      word = cluster.even? ? (word & 0xF000) | value : (word & 0x000F) | (value << 4)
      bytes[offset, 2] = [word].pack("v")
    else
      bytes[cluster * (bits / 8), bits / 8] = [value].pack(bits == 16 ? "v" : "V")
    end
  end

  def change_fat(fixture, cluster, value)
    2.times do |i|
      offset = (fixture[:reserved] + (fixture[:fatsz] * i)) * fixture[:bps]
      fat = fixture[:bytes][offset, fixture[:fatsz] * fixture[:bps]]
      set_fat(fat, cluster, value, fixture[:bits])
      fixture[:bytes][offset, fat.bytesize] = fat
    end
  end

  def source_for(bytes)
    MemorySource.new(bytes)
  end

  class MemorySource
    attr_reader :size

    def initialize(bytes)
      @bytes = bytes
      @size = bytes.bytesize
    end

    def read_at(offset, length)
      if offset.negative? || length.negative? || offset + length > size
        raise Sandcrawler::OutOfRangeError,
              "outside source"
      end

      @bytes.byteslice(offset, length).b
    end
  end
end
