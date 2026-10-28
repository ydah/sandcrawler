# frozen_string_literal: true

require "digest"

destination, source = ARGV
abort "usage: finish_fixtures.rb DEST SOURCE" unless destination && source

# Verify mtools' independent expected tree before accepting the generated corpus.
expected_files = {
  "home/app.rb" => "app.rb", "home/日本語のファイル名.rb" => "日本語のファイル名.rb",
  "lib/blob.bin" => "blob.bin", "empty.txt" => "empty.txt", "lib/nested/readme.txt" => "readme.txt"
}
Dir.glob(File.join(destination, "*.expected")).each do |tree|
  expected_files.each do |relative, original|
    actual = Digest::SHA256.file(File.join(tree, relative)).hexdigest
    expected = Digest::SHA256.file(File.join(source, original)).hexdigest
    abort "mtools round-trip mismatch: #{tree}/#{relative}" unless actual == expected
  end
end

volume = File.binread(File.join(destination, "fat12_4096.img"))
flash = "\xFF".b * (2 * 1024 * 1024)
flash[0, 300_000] = Random.new(42).bytes(300_000)
flash[0x100000, volume.bytesize] = volume
File.binwrite(File.join(destination, "flash_fat12_4096.bin"), flash)

bps = volume.byteslice(11, 2).unpack1("v")
spc = volume.getbyte(13)
reserved = volume.byteslice(14, 2).unpack1("v")
fats = volume.getbyte(16)
root_entries = volume.byteslice(17, 2).unpack1("v")
fat_sectors = volume.byteslice(22, 2).unpack1("v")
root_start = (reserved + (fats * fat_sectors)) * bps
data_start = root_start + (((root_entries * 32) + bps - 1) / bps * bps)
cluster_size = bps * spc

find_entry = lambda do |bytes, name|
  bytes.bytes.each_slice(32) do |slice|
    entry = slice.pack("C*")
    return entry if entry.byteslice(0, 11) == name
  end
  raise "Fixture entry missing: #{name}"
end
root = volume.byteslice(root_start, root_entries * 32)
home = find_entry.call(root, "HOME       ").byteslice(26, 2).unpack1("v")
lib = find_entry.call(root, "LIB        ").byteslice(26, 2).unpack1("v")
lib_entries = volume.byteslice(data_start + ((lib - 2) * cluster_size), cluster_size)
blob = find_entry.call(lib_entries, "BLOB    BIN").byteslice(26, 2).unpack1("v")

{
  "fat1_erased.bin" => [reserved * bps, bps],
  "boot_erased.bin" => [0, bps],
  "directory_erased.bin" => [data_start + ((home - 2) * cluster_size), cluster_size]
}.each do |filename, (offset, length)|
  damaged = volume.dup
  damaged[offset, length] = "\xFF".b * length
  raise "Fixture corruption changed size" unless damaged.bytesize == volume.bytesize

  File.binwrite(File.join(destination, filename), damaged)
end

looped = volume.dup
fats.times do |copy|
  offset = ((reserved + (copy * fat_sectors)) * bps) + blob + (blob / 2)
  pair = looped.byteslice(offset, 2).unpack1("v")
  pair = blob.even? ? (pair & 0xF000) | blob : (pair & 0x000F) | (blob << 4)
  looped[offset, 2] = [pair].pack("v")
end
File.binwrite(File.join(destination, "chain_loop.bin"), looped)
File.write(File.join(destination, "complete"), "dosfstools/mtools fixtures v1\n")
