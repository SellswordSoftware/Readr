# Readr

Reader is a small, offline, text-first EPUB reader for Playdate. It reads
ordinary unencrypted reflowable books from the Playdate data area.

## Build and run

You need Zig 0.16.0 and Playdate SDK 3.0.0 or newer. Set
`PLAYDATE_SDK_PATH` to the SDK directory.

```sh
zig build test  # host unit and integration tests
zig build       # make the .pdx package
zig build run   # package and open it in the simulator
```

For a validated hardware-only release:

```sh
./build.sh
```

The script requires Python 3 and `arm-none-eabi-objdump` in addition to the
toolchain above. It runs Debug and ReleaseFast host tests, builds Cortex-M7
device code in ReleaseFast, strips package debug data with `pdc -s`, and runs
the device stack guard. Resource compression remains enabled. Simulator
binaries are omitted. The device ELF retains loader relocation records and
symbols for the stack check; it is kept outside the shipping package.

Install or distribute `zig-out/release/readr.pdx`. The adjacent `pdex.elf`,
`SHA256SUMS`, and `build-info.json` provide diagnostics, per-file SHA-256
checksums, and build provenance. Builds use a fresh staging directory and
replace the previous release only after validation succeeds. Set `BUILD_JOBS`
to change the default two concurrent build jobs. Run the script from any
directory. Use `zig build run` for simulator development.

ReleaseFast favors reading responsiveness and disables Zig runtime safety
checks; the Debug test pass retains those checks. ReleaseSmall favors code
size instead, and ReleaseSafe would need its own device performance and stack
validation. This script retains the project's established ReleaseFast profile.

Playdate has about 10 KB of stack. The guard checks individual local frames;
it does not measure total call-chain or SDK stack use. The default Debug build
contains larger frames and exceeds this guard in existing reader and standard
library code.

## Sound

Settings → Sound offers **Off**, **Subtle**, and **Full** (default). Subtle
confirms page/chapter changes, panels, accepted actions, autoplay controls, and
errors. Full adds quiet selection ticks and reset-hold
progress pulses. The preference is saved across launches; system volume controls
loudness. Scrolling within a chapter, automatic RSVP words, and background
processing stay silent.

The fourteen procedural cue families are defined in `src/audio/sound_presets.zig`.
Semantic events and mixing policy are separate from the Playdate audio adapter,
so navigation behavior can be tested without playing sound.

Audio state, request batches, and preset scratch storage belong to the
heap-allocated app. Source presets are immutable compiled data, and the bounded
request queue uses insertion sort with one temporary. Avoid `std.mem.sort` here:
its block-sort workspace alone exceeds 8 KB on the device.

## Reader boundaries

`src/reader/reader_coordinator.zig` coordinates input, screens, and reader-engine results.
`src/reader/book_session.zig` retains publication metadata and closes temporary opening
storage. `src/reader/chapter_pump.zig` performs bounded lookup and byte delivery, owns
shared decode storage, and releases active file leases. `src/reader/reading_location.zig`
plans restoration and distinguishes semantic destinations from provisional
cursors when saving. `src/ui/reader_view.zig` defines borrowed, data-only screen models
for the renderer; consume a view before the next coordinator update.

Initialize session and pump storage in place and keep their addresses stable.
Streams borrow decoder storage, and an activated prefetch stream continues to
borrow its original session until EOF. Cache construction remains separate from
user movement and pace accounting. Every host supplies width and height for the
requested reading font.
