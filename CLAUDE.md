# CLAUDE.md — rtl-sca

FM SCA subcarrier decoder in Zig. **`SPEC.md` is the source of truth** for what to
build and in what order (Phases 1–5). This file covers how to work in the repo.

## Toolchain

- **Zig 0.16.0** (pinned via `minimum_zig_version` in `build.zig.zon`). Installed
  through Homebrew (`brew upgrade zig` to bump). 0.16 is a large break from 0.14 —
  most examples online assume older Zig. See "Zig 0.16 conventions" below before
  copying any idiom.

## Build & test

- `zig build` — compile, installs `zig-out/bin/rtl-sca`.
- `zig build run -- <args>` — build and run (e.g. `zig build run -- scan --freq 89.9M`).
- `zig build test` — run unit tests.

Develop the DSP chain against **recorded IQ first** (SPEC §11) — only go live once it
works on a file. Captures (`*.cu8`, `*.cs16`) and `*.wav` outputs are gitignored.

## Zig 0.16 conventions (avoid stale pre-0.15 idioms)

Generated/copied code commonly assumes Zig ≤0.14. The following are the patterns that
actually compile on 0.16 — prefer them:

1. **C interop through the build system, not `@cImport`.** `@cImport` is deprecated.
   Use `b.addTranslateC(...)` in `build.zig` and link C libs there
   (`translate_c.linkSystemLibrary("liquid", .{})`). Applies to `librtlsdr`,
   `miniaudio`, the FFT, and any liquid-dsp shim.
2. **Float→int with `@trunc` / `@round`**, not `@intFromFloat` (now deprecated/redundant).
   Cast builtins are **single-arg** with result-type inference: `@intCast(x)`,
   `@floatFromInt(x)` — never `@intCast(T, x)`. Wrap in `@as(T, ...)` when there's no
   result-type context. This hits every IQ-unpack and sample-write path.
3. **Thread `io` through all I/O.** Files/sockets are `std.Io.File` / `std.Io.Dir` and
   take an `io` param (`file.close(io)`). The `Source`/`Sink` interfaces must carry `io`.
   For the Phase-2 cross-thread ring buffer, use lock-free atomics (SPEC §3); do **not**
   use `std.Thread.Pool` (removed) — the async story is `io.async` / `io.Group`.
4. **`std.Io.Writer` buffered-writer pattern + `flush()`.** No `std.io.getStdOut()`.
   Construct an `Io.File.Writer` with a caller-owned buffer, write via `&fw.interface`,
   and `flush()`. See `src/main.zig` for the canonical shape.
5. **`ArrayList` is unmanaged** — `var l: std.ArrayList(T) = .empty;` then
   `l.append(allocator, x)`. The allocator is passed per call, not stored.
6. **Custom formatting:** `pub fn format(self, w: *std.Io.Writer) std.Io.Writer.Error!void`
   (no `comptime fmt`/`options`). `{}` no longer calls it — use **`{f}`**. New
   specifiers include `{t}` (tag name). Relevant for the `scan` results table.

## DSP hot-path rule

Pre-allocate all DSP buffers once at init (SPEC §3); the per-sample path must not
allocate. Each stage is a small allocation-free struct with a narrow interface.

## Working agreements

- Follow the global guardrails: minimal surgical diffs, no commits/pushes without
  explicit permission, no speculative dependencies.
- Build and validate each SPEC phase before starting the next.
- **Comments earn their keep and stand alone.** The DSP here is dense, so comments
  that pin down units, sample rates, frame conventions, or a non-obvious algorithm
  step are worth it (e.g. "alpha computed at the audio rate, not the MPX rate").
  Skip comments that restate the code or narrate a design change — that goes in the
  commit message.
