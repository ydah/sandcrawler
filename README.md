<h1 align="center">Sandcrawler</h1>

<p align="center">
  <strong>Read-only Ruby CLI for recovering files from Raspberry Pi Pico flash dumps, with FAT12/16/32 and UF2 support.</strong>
</p>

<p align="center">
  <a href="https://github.com/ydah/sandcrawler/actions/workflows/main.yml"><img src="https://github.com/ydah/sandcrawler/actions/workflows/main.yml/badge.svg?branch=main" alt="CI status"></a>
  <a href="#installation"><img src="https://img.shields.io/badge/Ruby-%3E%3D%203.1-CC342D?logo=ruby&amp;logoColor=white" alt="Ruby 3.1 or newer"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#damaged-volumes">Recovery</a> ·
  <a href="#documentation">Documentation</a>
</p>

---

Sandcrawler salvages files from Raspberry Pi Pico / Pico W (RP2040) and Pico 2 / Pico 2 W (RP2350) flash images, including devices running R2P2. Recover live files, deleted entries, orphaned cluster chains, and text fragments into a separate output directory, with hashes and warnings for each result.

> [!IMPORTANT]
> **Take a flash dump before using `flash_nuke.uf2`, reinstalling R2P2, or formatting a drive.** These operations can overwrite the files you want to recover. Keep the original dump and a second copy on another disk.

Sandcrawler does not repair or write to the device. Its picotool adapter permits only `version`, `info`, and `save`. Physical board and VM compatibility are **not yet validated**; see the [hardware checklist](docs/findings.md).

## Features

- **Raw and UF2 images** — locate FAT12, FAT16, and FAT32 volumes, including volumes embedded in a full flash dump.
- **File recovery** — extract live files, recover deleted entries and orphaned chains, or carve text fragments from damaged images.
- **Long filenames** — preserve Japanese and other Unicode names, with configurable code pages for short names.
- **Repeated flash reads** — compare SHA-256 hashes, retain every pass, and report blocks without a strict majority.
- **Multiple acquisition routes** — use BOOTSEL with picotool, copy a mounted volume, or transfer files through the R2P2 serial shell.
- **Traceable output** — retain readable partial files, record hashes and recovery warnings, and write a JSON manifest.

## Installation

### Requirements

| Requirement | When needed |
|---|---|
| Ruby 3.1+ | All commands; the core has no runtime gem dependencies |
| [picotool](https://github.com/raspberrypi/picotool) | BOOTSEL flash acquisition; RP2350 requires picotool 2.x |
| `serialport` gem | Serial acquisition only: `gem install serialport` |

Build and install from a checkout:

```sh
git clone https://github.com/ydah/sandcrawler.git
cd sandcrawler
gem build sandcrawler.gemspec
gem install ./sandcrawler-0.1.0.gem
sandcrawler --version
```

Install picotool separately when acquiring flash from a board. Set `PICOTOOL=/path/to/picotool` or pass `--picotool /path/to/picotool` to choose its executable. An existing raw or UF2 image needs only Ruby and Sandcrawler.

## Quick Start

### Recover an existing image

```sh
sandcrawler scan ./dump.bin
sandcrawler ls ./dump.bin --long --deleted
sandcrawler extract ./dump.bin -o ./recovered --deleted --orphans
```

Use the same commands with a `.uf2` image. Recovered files go into `./recovered`; [the manifest and exit code](#results) describe any incomplete or uncertain results.

### Acquire a device in BOOTSEL

Prefer BOOTSEL acquisition, which does not need R2P2 to start. Hold BOOTSEL while connecting the board, then:

```sh
sandcrawler doctor
sandcrawler dump -o ./rescue
sandcrawler scan ./rescue/dump.bin
sandcrawler ls ./rescue/dump.bin --long --deleted
sandcrawler extract ./rescue/dump.bin -o ./rescue/out --deleted --orphans
```

`auto -o ./rescue` offers interactive route selection and runs acquisition and extraction together.

### How recovery works

1. **Preserve the source.** Acquire a flash dump or work from an existing raw/UF2 image. Keep the original image after extraction.
2. **Locate the filesystem.** `scan` reports plausible FAT volumes with offsets and scores. `ls` and `extract` choose the highest-ranked candidate unless `--offset` selects another.
3. **Extract and inspect.** Save files into a separate directory, then inspect `manifest.json`, warnings, and any `.partial` files. Recovery assumptions are recorded alongside the results.

`dump` reads twice by default and compares SHA-256 hashes. If they differ, it reads once more and chooses the strict majority for each 4 KiB block. Every pass is retained. Blocks without a majority are listed in `dump.json` and cause exit code 5; producing an image does not imply its contents are reliable. `dump.bin` is made read-only and has a companion `dump.bin.sha256` file.

<details>
<summary>Acquisition timeouts and failed reads</summary>

Each picotool command has a 120-second timeout and a 1 MiB limit on each of stdout and stderr. If a failed save produced bytes, they are retained as `passN-all-failed.bin` or `passN-range-failed.bin` with an `acquisition_error` record and hash. Missing required hashes or acquisition metadata cause an integrity error.

</details>

## Alternative acquisition routes

### Mounted volume

If BOOTSEL is unavailable and the mounted R2P2 volume is readable:

```sh
sandcrawler copy /mnt/r2p2 -o ./copied
```

Use a read-only mount (`mount -o ro` on Linux). Although Sandcrawler only reads the source, the operating system may write hidden metadata to writable removable volumes. Symlinks are skipped. Keep the destination outside the source volume.

Detected file changes during copying produce `SOURCE_CHANGED` warnings and a partial-success result. Copying a running filesystem does not provide a consistent snapshot.

### Serial shell

For a running R2P2 shell on CDC0:

```sh
sandcrawler serial --port /dev/ttyACM0 -o ./serial-copy
```

Without `--port`, the CLI lists candidates and asks for a selection. Choose the shell port, not debug or MIDI. Serial acquisition interrupts `app.rb`, enters IRB, probes APIs, and verifies hexadecimal chunks against a byte count and checksum. Session-specific marker tokens distinguish protocol responses from unrelated output. Failed transfers are retried up to three attempts. Device startup and unrelated running software can still alter flash; use BOOTSEL when possible.

<details>
<summary>Serial transfer limits</summary>

Serial requests have a 10-second idle timeout and a one-hour total deadline. Each request accepts at most 65,537 response records and 40 MiB of encoded responses, supporting files up to 16 MiB with the fixed 256-byte chunks. Incomplete listings, duplicate names, invalid frames, and oversized responses are rejected. These limits are built in; there are no CLI options to increase them.

</details>

## Usage

### Commands

| Command | Purpose |
|---|---|
| `doctor` | Check Ruby, picotool, USB access, and optional serial support |
| `dump -o DIR` | Read flash; `--passes N` sets the initial read count (default 2) |
| `scan IMAGE` | Rank FAT candidates in raw or UF2 images |
| `ls IMAGE` | List files; `--long` adds metadata, `--deleted` includes deleted entries |
| `extract IMAGE -o DIR` | Extract files; `--deleted`, `--orphans`, and `--carve` enable recovery |
| `copy MOUNTPOINT -o DIR` | Copy a mounted volume with hashes |
| `serial -o DIR [--port PORT]` | Copy through the R2P2 shell |
| `auto -o DIR` | Choose a route interactively |

`--help` lists options. `--json` emits machine-readable results, `--verbose` adds diagnostics, and `--quiet` suppresses routine progress. `--force` permits a nonempty destination; use a new output directory to preserve earlier recovery results unchanged.

### Image options

| Image option | Meaning |
|---|---|
| `--offset N` | Volume byte offset, decimal or `0x` hexadecimal |
| `--fat 1` / `--fat 2` | Force a FAT copy; otherwise erased sectors may fall back to the other copy |
| `--codepage NAME` | Short filename encoding (default `IBM437`; for example `CP932`) |
| `--reference-image FILE` | Borrow geometry from a healthy image with the same firmware and layout |
| `--geometry KEY=VALUE,...` | Supply geometry when the boot sector is damaged |

## Damaged volumes

Try a healthy reference dump from a **separate test board** with the same firmware and flash layout:

```sh
sandcrawler extract broken.bin -o ./with-reference --reference-image healthy.bin
```

<details>
<summary>Manual geometry and backup boot sectors</summary>

Manual geometry requires `bps` (bytes per sector), `spc` (sectors per cluster), `rsvd` (reserved sectors), `fats` (copy count), `fatsz` (sectors per FAT), and `root` (FAT12/16 root entry count, or zero for FAT32). Optional keys are `offset` (byte offset), `total` or `totsec` (total sectors, otherwise inferred from remaining image size), `root_cluster` (FAT32, default 2), and `media` (default 248). The following values are illustrative; substitute measured geometry:

```sh
sandcrawler extract broken.bin -o ./manual \
  --geometry bps=4096,spc=1,rsvd=1,fats=2,fatsz=1,root=128,total=256,offset=0x100000
```

Missing fields, duplicate keys, conflicting `total`/`totsec`, and invalid geometry produce usage error 2. When a FAT32 backup boot sector has matching FAT copies and a plausible root entry, detection can recover the volume's original offset and records a `BACKUP_BOOT_SECTOR` warning.

</details>

```sh
sandcrawler extract broken.bin -o ./carved --carve
```

With no readable volume, `--carve` searches the whole image. Deleted-file recovery assumes consecutive free clusters and stops before allocated data. Original fragmentation and overwritten bytes cannot be reconstructed reliably. Orphan chains have no authoritative filename or length, so final clusters can include padding. Carving groups adjacent valid UTF-8 blocks with at least 95% printable characters; it cannot establish file boundaries or recover arbitrary binaries. Inspect every recovery result.

## Results

```text
out/
  files/           live files; .partial suffix when incomplete
  deleted/         best-effort undeleted files
  lost+found/      unreferenced chains
  carved/          text fragments
  manifest.json    provenance, paths, hashes, statuses, warnings
  sandcrawler.log  diagnostics
```

The manifest records the source image's SHA-256 and size, geometry and FAT selection, original names, safe output paths, hashes, timestamps, attributes, and warnings. Its `directories` list also records directory metadata and creation failures. Invalid FAT timestamps are `null`. Unsafe path components, Windows reserved names, and case-insensitive collisions are renamed; original names remain in the manifest. Invalid UTF-8 path and name bytes are preserved in companion `_hex` fields. Console diagnostics escape control characters.

`ok` means no read/structure error was detected, not that historical contents are proven intact. `truncated` and `chain_error` identify incomplete or broken chains; `suspect_erased` identifies all-`0xFF` clusters. `read_error` records an unreadable file or carving block; readable prefixes are preserved and other files or blocks are still attempted. Recovery warnings explain assumptions. Keep the source image after extraction.

Extraction rechecks the image and any reference image against their original SHA-256 hashes before finishing. A changed or unreadable input produces `SOURCE_CHANGED` and exit code 5; recovered files and the failure manifest remain available for inspection.

| Exit code | Meaning |
|---|---|
| 0 | Success |
| 1 | General error |
| 2 | Invalid usage |
| 3 | Device unavailable |
| 4 | Partial success; inspect statuses and warnings |
| 5 | Integrity error, including unresolved dump disagreement or changed extraction input |

## Troubleshooting

| Symptom | Next step |
|---|---|
| No device | Check BOOTSEL, a data-capable cable, and USB permissions; Linux may need picotool's udev rules |
| Different dump hashes | Connect directly without a hub, retain all passes, and inspect unstable blocks |
| No FAT candidate | Check the offset, use matching reference geometry, then try carving |
| Garbled short filename | Try the firmware's code page, such as `CP932` |
| Partial files | Inspect `lost+found/` and `carved/`; keep the original image |
| Serial timeout / unsupported API | Check CDC0 and firmware/VM details; use BOOTSEL if available |

## Development

```sh
bundle install
bundle exec rake test
bundle exec rubocop
bundle exec ruby exe/sandcrawler --version
```

Install dosfstools and mtools for independent integration fixtures (`brew install dosfstools mtools` or `sudo apt install dosfstools mtools`), with their executables on `PATH`. `rake test` builds missing fixtures when tools are available; otherwise it warns, runs synthetic unit tests, and skips external-fixture integration. Require full coverage with `REQUIRE_FIXTURES=1 bundle exec rake test`.

`script/build_fixtures.sh` creates FAT12 with 512/4096-byte sectors, FAT16, FAT32, Japanese names, empty/multi-cluster files, deleted files, embedded volumes, and corruption cases. Expected trees come from `mcopy` and are checked against original content. Generated files are ignored by Git. CI generates on Ubuntu and shares fixtures with Ubuntu, macOS, and Windows jobs for Ruby 3.1 and maintained Ruby branches.

## Documentation

| Guide | Contents |
|---|---|
| [Software verification](docs/verification.md) | Requirement coverage, adversarial cases, and recorded test environments |
| [Hardware checklist](docs/findings.md) | Measurements required to validate a board, firmware, and VM combination |
| [Release procedure](docs/releasing.md) | Build, package, and publication checks |
| [Changelog](CHANGELOG.md) | Release history and unreleased changes |

Hardware acceptance is separate from image tests. Complete the hardware checklist before claiming a board/firmware/VM combination is validated.

## License

[MIT](LICENSE.txt).
