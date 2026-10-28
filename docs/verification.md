# Software verification

This records the software acceptance scope for the implementation and adversarial review on 2026-10-28. Physical Pico testing and execution on Windows are outside this verification run. They are not implied by the passing software tests; physical acceptance remains documented in [findings.md](findings.md).

## Independent acceptance oracle

`script/build_fixtures.sh` uses dosfstools and mtools to construct FAT12 (512-byte and 4096-byte sectors), FAT16, and FAT32 images. It writes known original files and obtains the expected trees with `mcopy`. The generator verifies those trees against the originals before marking the corpus complete. Generated artifacts are excluded from the repository.

`test/acceptance/offline_acceptance_test.rb` exercises the CLI rather than only the FAT reader. It checks:

- All four filesystem types: exact directory and filename sets, every file's SHA-256, empty files, nested files, Japanese filenames, and multi-cluster binary content.
- A complete flash image and an equivalent UF2 with blocks in reverse order: identical extracted trees and volume geometry, the correct embedded-volume offset, and source hashes.
- An erased FAT copy and an erased boot sector with a healthy reference image: unchanged live file contents, explicit recovery warnings, and successful status.
- A deleted file: exact recovered bytes and a status that identifies the recovery assumption.
- An erased directory: unaffected siblings plus orphan contents matching the lost originals; unknown file lengths are not treated as authoritative.
- A cyclic chain: the exact readable prefix has a `.partial` suffix, intact siblings remain correct, and the command reports partial success.

Every acceptance extraction also checks that stdout JSON matches `manifest.json`, that recorded file hashes and sizes match the output bytes, that recorded timestamps match restored timestamps, and that the input image's hash is unchanged.

## Requirement coverage

| Requirement | Software evidence | Boundary |
|---|---|---|
| FR-01 / FR-02: acquisition and repeated reads | Fake picotool process tests verify allowed commands, pass counts, hashes, strict block majority, range fallback, and failures | Real USB devices and picotool-to-board compatibility require physical testing |
| FR-03: raw/UF2 volume detection | Embedded-volume, MBR, UF2 validation, and full CLI raw/UF2 parity tests | A damaged boot sector can still require manual or reference geometry |
| FR-04 / FR-05: FAT parsing and faithful extraction | Independent expected trees for FAT12/16/32; LFN/codepage/timestamp tests; output acceptance checks | Invalid timestamps remain unknown; FAT timestamps have no timezone metadata |
| FR-06: mismatched and erased FAT copies | Copy selection, FAT32 active-copy, mixed-sector and erased-allocation tests | Disagreement without a uniquely healthy copy remains uncertain and is reported |
| FR-07 / FR-08 / FR-09: recovery | Deleted, orphan, cycle, cross-link, and carving tests with exact content expectations | Deleted fragmentation and original orphan/carved file boundaries cannot be proven |
| FR-10: serial transfer | Generated template execution plus pipe-based peers, checksums, listing completeness, retries, protocol validation and bounded failures | Actual firmware prompts and VM APIs require physical testing; individual file transfers are limited to 16 MiB |
| FR-11: mounted copy | Tree/content/timestamp tests, hidden files, literal mount names, symlink rejection, changed files and failed reads | The host OS may independently write to a writable source mount; this is not an atomic snapshot |
| FR-12 / NFR-04: provenance | Manifest/stdout agreement, source and output hashes, directory metadata, original byte names, failure reporting and post-extraction source verification | Source state changing outside Sandcrawler cannot establish historical provenance |
| NFR-01: read-only acquisition | Command/argument allowlists and fixed read-only serial templates | Serial startup interrupts the application; other device software is outside the tool's control |
| NFR-02: minimal dependencies | Gem metadata and installed executable checks; the core uses the Ruby standard library | Serial communication additionally needs the optional `serialport` gem |
| NFR-03: platforms and Ruby | Local macOS and Linux container runs; Ruby 3.1 and 4.0 checks; CI configuration includes Windows | No Windows execution or remote CI run is claimed |
| NFR-05: damaged-input robustness | Seeded metadata mutation, bounded chains/protocols, injected read/write failures, and preserved partial results | These are defined adversarial cases, not a proof over every possible byte sequence |
| NFR-06: safe output | Traversal/reserved-name/collision tests, symlink rejection, and atomic output checks | Output directories must not be concurrently manipulated by another process |

## Adversarial fixes verified

The review used concrete malformed images, injected I/O failures, fake subprocesses, and scripted serial peers. Regression tests cover the corrected behavior:

- FAT32 backup boot sectors no longer become a false volume at the backup sector's own offset when the primary is erased and the image has trailing bytes. The recovered original offset and `BACKUP_BOOT_SECTOR` evidence are recorded.
- FAT structural `.` and `..` entries are identified before codepage decoding. Metadata corruption, cycles, cross-links, erased allocation entries, and directory terminators are checked without falsely treating damaged results as intact files.
- A failed streamed read retains the readable prefix with a `.partial` suffix. Early EOF is compared with the expected size. Directory creation failures are recorded while independent entries remain recoverable.
- Invalid UTF-8 source and entry names no longer abort JSON or diagnostic logging. Companion `_hex` fields retain original path and name bytes, distinct invalid-byte directory names remain distinct, and terminal control characters are escaped.
- Missing, duplicate, contradictory, and invalid manual geometry produce usage error 2. Image and reference hashes are rechecked after extraction; changes produce `SOURCE_CHANGED`, exit 5, and a saved failure manifest.
- Mounted paths containing glob characters no longer produce silently empty copies. Source symlinks and replaced source entries are rejected. Detected rewrites during copying are reported instead of marking the result `ok`.
- Serial listings require a verified terminator, count, checksum, and unique names. Unexpected, incomplete, or malformed transfer frames fail. Requests stop after the idle timeout, one-hour deadline, 65,537 records, or 40 MiB of encoded responses.
- picotool commands stop after 120 seconds by default or when either stdout or stderr exceeds 1 MiB. Failed saves preserve any acquired bytes and their hashes before fallback. Invalid UTF-8 device information remains serializable with original bytes in `info_hex`. Required acquisition sidecar failures and changed pass lengths are integrity errors.

Final independent probes reconfirmed the invalid-name error path, directory collision separation, invalid geometry exit codes, and erased-primary FAT32 backup recovery. The independent CLI acceptance file still passed after these fixes: 6 tests, 264 assertions, no failures, errors, or skips.

## Reproduce

```sh
bundle install
bundle exec rake fixtures
REQUIRE_FIXTURES=1 bundle exec rake test
bundle exec rubocop
actionlint
gem build sandcrawler.gemspec
```

The strict `REQUIRE_FIXTURES=1` run must contain no fixture-related skips. Missing dosfstools/mtools or an absent generated corpus must not be interpreted as successful independent acceptance. The CI workflow generates fixtures once on Ubuntu and supplies the same corpus to each platform job.

The acceptance file can also be run on its own:

```sh
REQUIRE_FIXTURES=1 bundle exec ruby -Itest test/acceptance/offline_acceptance_test.rb
```

After all adversarial fixes, the complete suite passed **127 tests and 1,686 assertions**, with **zero failures, errors, or skips**, in each environment below:

| Environment | Ruby | Result |
|---|---|---|
| macOS | 4.0.9 | Full suite, including generated fixtures, passed |
| macOS | 3.1.0 | Full suite passed; unrelated globally installed minitest plugins disabled |
| Linux container | 4.0.9 | Full suite passed with networking disabled and the checkout mounted read-only |

Mutation checks include 200 FAT metadata cases and 100 UF2 cases with fixed seeds. These supplement the independent mtools comparisons and exact damaged-file expectations. No Windows execution, physical-device acceptance, remote CI result, or RubyGems publication is claimed.
