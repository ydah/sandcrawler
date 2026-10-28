#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export MTOOLS_SKIP_CHECK=1
export LC_ALL=C.UTF-8
RUBY="${RUBY:-ruby}"
OUT=test/fixtures/generated

for tool in mkfs.fat mmd mcopy mdel; do
  command -v "$tool" >/dev/null || { echo "Missing $tool; install dosfstools and mtools." >&2; exit 1; }
done
if [[ -f "$OUT/complete" ]]; then
  exit 0
fi
if [[ -e "$OUT" ]]; then
  echo "$OUT exists but is incomplete; move it aside before rebuilding." >&2
  exit 1
fi

mkdir -p test/fixtures
STAGE=$(mktemp -d test/fixtures/.build.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/source" "$STAGE/generated"
SRC="$STAGE/source"
DEST="$STAGE/generated"

printf 'puts "Hello, R2P2"\n' > "$SRC/app.rb"
printf '# 日本語\nputs "こんにちは"\n' > "$SRC/日本語のファイル名.rb"
printf 'A nested file.\n' > "$SRC/readme.txt"
: > "$SRC/empty.txt"
"$RUBY" -e 'File.binwrite(ARGV.fetch(0), Random.new(42).bytes(100_000))' "$SRC/blob.bin"

build() {
  local name="$1" bits="$2" sector="$3" kib="$4"
  local img="$DEST/$name.img"
  mkfs.fat -C -F "$bits" -S "$sector" -s 1 -n R2P2 "$img" "$kib" >/dev/null
  mmd -i "$img" ::/home ::/lib ::/lib/nested
  mcopy -i "$img" "$SRC/app.rb" ::/home/app.rb
  mcopy -i "$img" "$SRC/blob.bin" ::/lib/blob.bin
  mcopy -i "$img" "$SRC/empty.txt" ::/empty.txt
  mcopy -i "$img" "$SRC/readme.txt" ::/lib/nested/readme.txt
  mcopy -i "$img" "$SRC/日本語のファイル名.rb" ::/home/
  mcopy -i "$img" "$SRC/app.rb" ::/home/old.rb
  mdel -i "$img" ::/home/old.rb
  mkdir "$DEST/$name.expected"
  mcopy -s -n -i "$img" '::*' "$DEST/$name.expected/"
}

build fat12_512 12 512 512
build fat12_4096 12 4096 1024
build fat16_512 16 512 8192
build fat32_512 32 512 65536

"$RUBY" script/finish_fixtures.rb "$DEST" "$SRC"
mv "$DEST" "$OUT"
