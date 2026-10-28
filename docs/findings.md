# Hardware findings and acceptance checklist

Status: **not measured on physical hardware**. Synthetic images and mocked transports cannot answer the six questions below. No Pico has been flashed, erased, deliberately corrupted, or used for acquisition during implementation. Test offsets are not device measurements.

## Open questions

| Question | Current result | Evidence needed |
|---|---|---|
| FAT offset and size | Unverified; detected or supplied per image | Firmware, board, matching dumps, `scan --json` output |
| Logical sector size | Unverified; parser accepts 512/1024/2048/4096 | Physical BPB and independently checked extraction hashes |
| MBR presence | Unverified; scanner considers partition starts | MBR bytes, partition entries, selected offset |
| Logical-to-physical mapping | Unverified; parser assumes linear mapping | Multi-cluster files match independent source hashes |
| Startup flash writes | Unverified; do not assume boot preserves evidence | Before/after dumps around a controlled boot |
| File/Dir APIs for each VM | Unverified; serial probes capabilities | Capability transcript and transfer hashes per firmware/VM |

Nonlinear storage would require an additional mapping layer before raw recovery can be trusted. No mapping has been inferred from an untested firmware version.

## Record each test

Use a separate test board. Never experiment on the only recoverable copy of a device's data. Record:

- Board, chip, flash capacity, firmware repository and exact release/commit, build settings, VM.
- Host OS, Ruby/picotool versions, dump hashes, retained artifact location.
- FAT offset/size/type, sector/cluster sizes, MBR result.
- Original file hashes and hashes from each acquisition route.
- Raw serial capability transcript, retries, missing APIs.
- Flash blocks changed on startup, exact boot procedure, warnings, exit codes, observed losses.

## Procedure

1. On the test board only, install chosen firmware and create `home/app.rb`, nested directories, a Japanese filename, an empty file, and a 100 KB binary. Record their SHA-256 hashes on the host.
2. Safely unmount, disconnect, reconnect in BOOTSEL, and run `sandcrawler dump -o before`. Require matching pass hashes.
3. Run `scan before/dump.bin --json` and `extract before/dump.bin -o extracted`. Compare every output hash to the originals. This supplies evidence for geometry and linear mapping.
4. On the test board only, boot normally and record what runs. Return to BOOTSEL, dump to `after`, and compare 4 KiB blocks. Record changed offsets and repeat only if needed for the experiment.
5. Capture the serial capability output and copy via CDC0. Copy the read-only mounted volume separately. Compare both routes against originals and flash extraction.
6. Delete a known file on the test board, dump again, and check `extract --deleted` against the original content.
7. Only with expendable data and a disposable test board, interrupt a write and evaluate `--deleted --orphans --carve`. Record exact losses. Never run this experiment on a rescue target.

## Acceptance matrix

| Board | VM | BOOTSEL dump | Mounted copy | Serial copy |
|---|---|---|---|---|
| Pico | femtoruby | Pending (required) | Pending (required) | Pending (required) |
| Pico 2 | femtoruby | Pending (required) | Pending (optional) | Pending (optional) |
| Pico 2 | picoruby | Pending (required) | Pending (optional) | Pending (required) |
| Pico W | firmware-specific | Pending (optional) | Pending (optional) | Pending (optional) |
| Pico 2 W | firmware-specific | Pending (optional) | Pending (optional) | Pending (optional) |

Completion requires measurements for all six questions and every required matrix cell. Software tests alone do not complete this checklist.
