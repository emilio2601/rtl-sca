# rtl-sca — Design Notes

> **Status:** this started as the build spec / source of truth and is now the
> original design doc. The project is built — **the shipped code is authoritative**
> where the two disagree. Kept for the signal-chain background and rationale
> (Carson bandwidth, de-emphasis, the MPX layout, the rate chain), which the code
> doesn't spell out. The phase plan below is historical.

A command-line tool to detect, demodulate, and play back FM broadcast
subcarriers (SCA and related) from an RTL-SDR. Written in **Zig**.

The file-source-first workflow it describes still holds: develop and validate the
DSP against recorded IQ before touching live hardware.

---

## 1. Background (what we're decoding)

A US FM broadcast station at e.g. 89.9 MHz is frequency-modulated by a **composite
MPX baseband** signal spanning roughly 0–100 kHz. That composite contains, in order:

| Component        | Frequency        | Notes                                        |
|------------------|------------------|----------------------------------------------|
| Mono (L+R)       | 0–15 kHz         | main program audio                           |
| Stereo pilot     | 19 kHz           | presence ⇒ stereo                            |
| Stereo (L−R)     | 23–53 kHz (DSB)  | suppressed-carrier DSB around 38 kHz         |
| RDS              | 57 kHz           | 1187.5 bps, biphase — out of scope for MVP   |
| **SCA #1**       | **67 kHz**       | most common audio subcarrier (reading svc.)  |
| **SCA #2**       | **92 kHz**       | second audio subcarrier                      |

The job of this tool: recover the FM main carrier to get the MPX, reach into a
chosen subcarrier slot, demodulate it, and play it back.

Two facts that drive the design:

- **SCA audio subcarriers are normally FM**, with **150 µs de-emphasis** (NOT the
  75 µs used on the main channel). Default de-emphasis for SCA mode is 150 µs.
- **Some subcarrier energy is AM/DSB**, either intentionally or as bleedthrough
  (main program audio coupling into the MPX through the transmitter chain). So the
  tool must support both FM and AM demodulation and, ideally, *detect which is which*.

---

## 2. Signal chain

```
IQ source ─► FM demod ─► MPX composite ─► subcarrier select ─► subcarrier demod ─► de-emphasis ─► resample ─► sink
 (file/      (polar      (real signal,    (NCO mix-down +      (FM discriminator   (1-pole IIR,   (to audio   (audio dev
  rtl_tcp/    discrim.)   0–100 kHz)       decimating LPF)      OR AM env/coherent) configurable)  out rate)   / WAV)
  usb)
```

Every stage is a small, allocation-free Zig struct with a narrow interface. The
whole tool is just making each stage configurable and wiring them together.

The **main program audio is the slot at 0 Hz**: the same chain recovers it with no
NCO mix-down, a wider channel (~15 kHz), and 75 µs de-emphasis. Mono main-channel
reception is in scope as a validation/utility mode (`--sub 0`). Stereo decode
(pilot-locked 38 kHz DSB) is out of scope.

---

## 3. Module layout

Each is one Zig file with a tight public interface. Pre-allocate all DSP buffers
once at init; the hot path must not allocate.

- `src/main.zig` — entry point, wires CLI → pipeline.
- `src/cli.zig` — argument/subcommand parsing.
- `src/source.zig` — the `Source` abstraction. Backends:
  - `FileSource` — reads `.cu8` (uint8 IQ) and `.cs16` (int16 IQ). **Build this first.**
  - `RtlTcpSource` — connects to an `rtl_tcp` server over TCP (host:port), sends
    the tune/rate commands, streams IQ. First-class — this is how it runs remotely
    on a Pi.
  - `UsbSource` — direct `librtlsdr` via `@cImport`. Last to build.
  - Interface: `fn read(self, buf: []u8) !usize` delivering interleaved IQ blocks,
    plus `setFreq`, `setSampleRate`, `setGain`.
- `src/fmdemod.zig` — IQ → real MPX. Polar discriminator:
  `y[n] = atan2(Im(x[n]·conj(x[n-1])), Re(x[n]·conj(x[n-1])))`. Keep last sample as state.
- `src/firdecim.zig` — windowed-sinc FIR lowpass + integer decimation. Generate
  taps at **comptime** from cutoff/transition/decimation (Kaiser or Hamming window).
- `src/nco.zig` — numerically-controlled oscillator / complex mixer for shifting a
  subcarrier slot down to baseband. Incremental complex phasor, periodic renormalize.
- `src/subcarrier.zig` — orchestrates: NCO mix-down to DC → decimating FIR to the
  subcarrier bandwidth (~8 kHz) → hand off to the chosen demodulator.
- `src/demod_fm.zig` — FM discriminator (same primitive as fmdemod, reused).
- `src/demod_am.zig` — two AM paths:
  - **envelope**: analytic signal magnitude (Hilbert FIR → `hypot(re, im)`), then DC block.
  - **coherent DSB**: mix by recovered carrier and LPF. For a **pilotless** subcarrier
    (e.g. bleedthrough), use a **Costas loop** to recover phase.
- `src/deemph.zig` — single-pole IIR de-emphasis (see §5).
- `src/rateplan.zig` + `src/resampler.zig` — derive the full rate chain from the input
  and `--audio-rate` targets, then a rational (L/M) resampler bridges to any output rate.
- `src/detect.zig` — survey / classification mode (see §6). The differentiator.
- `src/sink.zig` — `WavSink` (write `.wav`) and `AudioSink` (live playback via
  `miniaudio`, single-header C through `@cImport`). A lock-free ring buffer sits
  between the source/DSP thread and the audio callback thread.

---

## 4. Sample-rate plan (get this right — see gotchas)

Reference flow for a 67 or 92 kHz subcarrier:

1. RTL-SDR sample rate: **1.024 Msps** (clean integer relationships downstream).
2. FM demod → MPX at 1.024 Msps (real).
3. Decimate MPX by 4 → **256 ksps**. This is the *lowest* you may go before
   subcarrier extraction (must stay above ~200 ksps so the 92 kHz slot and its
   sidebands survive — see §7).
4. NCO mix the target subcarrier (67k or 92k) down to DC at 256 ksps.
5. Decimating FIR to an ~8 kHz-wide channel, decimate by 16 → **16 ksps**.
6. Demodulate (FM or AM) at 16 ksps.
7. De-emphasis at 16 ksps (compute the coefficient at *this* rate — see §5).
8. Resample to output rate (16 ksps is acceptable for narrowband SCA audio; 48 ksps
   if the audio device prefers it).

Make the decimation factors derived from configured rates, not hardcoded, but ship
these as the defaults.

---

## 5. De-emphasis (configurable — key feature)

Single-pole IIR:

```
y[n] = y[n-1] + alpha * (x[n] - y[n-1])
alpha = dt / (tau + dt),   dt = 1 / Fs_audio
```

- **Compute `alpha` AFTER the final decimation**, using the actual audio-stage
  sample rate (`Fs_audio`), not the MPX rate. This is a common bug.
- Configurable time constant `tau`:
  - `150us` — **default for SCA mode** (67/92 kHz audio subcarriers)
  - `75us` — main-channel constant; offer it because a few operators use it
  - `off` — no de-emphasis (data subcarriers, or raw inspection)
- Worked example: at `Fs_audio = 16000`, `dt = 62.5 µs`, `tau = 150 µs` ⇒
  `alpha ≈ 0.294`.

---

## 6. Survey / detection mode (the differentiator)

`rtl-sca scan` should tell the user what's present *before* they commit to demodulating.

Algorithm:

1. FM demod the MPX, compute an averaged PSD (Welch) over 0–100 kHz.
2. Detect the **19 kHz pilot** (⇒ stereo present).
3. Find energy peaks near **57, 67, 92 kHz** (and report any other strong slots).
4. For each detected subcarrier, **classify modulation** straight from the PSD — no
   per-slot demodulation, so it stays cheap (a full scan is <1 s on a Pi 4):
   - **Carrier presence** (the FM discriminant): the slot's center-bin power vs its
     shoulders. A present carrier (center spike) ⇒ **FM**. This is content-independent —
     a carrier reads the same whether its program is loud or silent, unlike an
     audio-content metric (which mislabels a quiet SCA as noise).
   - **Suppressed carrier**: a spectral null at center + symmetric sidebands + broadband
     at real SNR ⇒ **AM/DSB** (the 38 kHz stereo L−R).
   - **Standardized slots** assert their type by the FM standard regardless of the metric:
     38 kHz ⇒ stereo (DSB-SC), 57 kHz ⇒ RDS (data).
   - Otherwise ⇒ **unknown**. A non-standard slot is also dropped as an overload spur
     unless it occupies a plausible bandwidth (neither a single-bin tone nor broadband
     splatter).
5. Estimate per-slot bandwidth and SNR.

Labels stick to facts: standardized pilot-locked assignments (38 kHz stereo, 57 kHz RDS)
and the measured modulation — never guessed content (a reading service vs music).

Output a table, e.g.:

```
slot     mod      bw       snr     guess
67 kHz   fm       ~5 kHz   18 dB   audio SCA
38 kHz   am_dsb   ~8 kHz   12 dB   stereo subcarrier (L−R)
57 kHz   data     ~3 kHz    9 dB   data subcarrier (RDS)
```

Standardized slots (38 kHz stereo, 57 kHz RDS) assert their known modulation rather than
trust the metric. The report also filters broadband junk — non-standard regions that are
noise-level, or wide and unclassified, are overload/MPX splatter, not subcarriers.

---

## 7. Gotchas — front-load these

- **Nyquist trap (most important):** do NOT decimate the MPX below ~240 ksps before
  extracting the subcarrier. The 92 kHz slot with sidebands extends to ~99 kHz and
  needs Fs > ~198 kHz to survive. Decimate-by-4 from 1.024M → 256 ksps is the safe
  first stage. Only decimate hard *after* mixing the chosen slot down to DC.
- **De-emphasis coefficient timing:** compute `alpha` from the final audio rate, not
  the MPX rate (§5).
- **Low injection ⇒ low SNR:** SCA subcarriers are only ~10% of total modulation, so
  they're weak relative to main program audio. SNR is the real enemy; survey mode
  should report it honestly rather than pretending a slot is clean.
- **Pilotless AM needs a Costas loop or envelope detection**, not naive coherent mix —
  there's no carrier reference to lock to.
- **Renormalize the NCO phasor** periodically to prevent amplitude drift.

---

## 8. Build phases

Build and validate each phase before starting the next.

**Phase 1 — MVP (offline, no hardware):**
`FileSource (.cu8)` → FM demod → fixed 67 kHz FM subcarrier → 150 µs de-emph →
`WavSink`. Validate end-to-end against a recorded IQ file. No live radio, no audio
device, no CLI polish. Prove the DSP works first.

Sanity check: the same chain with `--sub 0`, ~15 kHz bandwidth, and 75 µs de-emphasis
recovers the station's main program audio. If that is clearly audible, the front-end,
FM demod, and de-emphasis are proven before chasing a weak ~10%-injection subcarrier.

**Phase 2 — live + audio:**
Add `RtlTcpSource` and `UsbSource`, `AudioSink` (miniaudio) with the ring buffer
between the RTL callback thread and the DSP thread.

**Phase 3 — configurable:**
Expose main freq, subcarrier freq, modulation mode (fm/am), and de-emphasis constant
as CLI flags. Add the AM demod paths.

**Phase 4 — survey mode:**
Implement `scan` (§6): PSD, pilot + slot detection, AM-vs-FM classification, SNR.

**Phase 5 — stretch (optional):**
RDS decode at 57 kHz (its own mini-project: 1187.5 bps biphase, offset-word sync);
a headless daemon build for the Pi; arbitrary-rate resampler.

---

## 9. CLI

```
rtl-sca scan  89.9M
rtl-sca play  89.9M       --sub 67k --mod fm --deemph 150us
rtl-sca rec   89.9M       --sub 67k -o gatewave.wav
rtl-sca play  capture.cu8 --sub 86k --mod am --deemph off
```

Form: `rtl-sca <command> <input> [flags]`.

`<input>` is the single required positional. It is auto-detected:
- if it parses as `<number>[kMG]?` (e.g. `89.9M`, `89900000`) it is the **main FM
  carrier frequency** (tune a radio);
- otherwise it is a **file path** → use `FileSource` instead of a radio.

Flags:
- `--source` file path; explicit, unambiguous override of the positional (use in
  scripts, or for a file whose name looks like a frequency). Implies `FileSource`.
- `--remote host[:port]` to use a network (`rtl_tcp`) source. The host is a literal IP
  or a name resolved through the OS (DNS, `/etc/hosts`, mDNS); the port defaults to
  rtl_tcp's `1234`.
- `--sub` subcarrier center (`67k`, `92k`, arbitrary Hz). Default `67k`. `--sub 0`
  selects the **main program channel** (use `--bw 15k --deemph 75us` with it).
- `--bw` subcarrier channel bandwidth (default ~`8k`, SCA voice; `~15k` for the main
  channel). Applies to file sources too.
- `--mod` `fm` | `am-env` | `am-coherent` (default `fm`).
- `--deemph` de-emphasis time constant — any value with an optional `us` suffix
  (e.g. `120us`), or `off` (tau = 0). Not a fixed set: it is just `tau` feeding
  `alpha = dt/(tau+dt)` at the audio rate (§5). The standard values are `150us`
  (SCA, default), `75us` (US main channel), and `50us` (EU main channel); other
  values exist for non-standard or unknown subcarriers.
- `--rate` RTL sample rate (default `1.024M`). Also applies to a file source (the
  recording's IQ rate).
- `--gain` tuner gain (default auto). Radio-only.
- `--device` USB dongle index (default `0`), for selecting among multiple dongles.
  USB source only.
- `--ppm` crystal frequency-error correction in ppm (default `0`). Radio-only;
  forwarded over `rtl_tcp` too.
- `-o` output WAV path for `rec`.

Radio-only flags (`--gain`, `--ppm`, `--device`, `--remote`) are an error when the
input is a file source.

Frequency tokens (the positional, `--sub`, `--rate`) accept a `k`/`M`/`G` suffix or
raw Hz. Value flags accept both `--flag value` and `--flag=value`.

---

## 10. Dependencies & build

- **Zig 0.16+** with `build.zig` (pinned via `minimum_zig_version` in `build.zig.zon`).
  Target builds for host and cross-compiles to ARM (Raspberry Pi) cleanly. See
  `CLAUDE.md` for the 0.16-specific conventions (translate-c over `@cImport`, the
  `std.Io` writer/reader pattern, float→int builtins, unmanaged `ArrayList`).
- **MVP uses pure-Zig DSP** — implement the FIR decimator, NCO, FM discriminator,
  AM envelope, and de-emphasis IIR directly. No C DSP dependency for Phases 1–3.
  Comptime tap generation for the FIR is preferred.
- **C deps via the build system's translate-c** (Zig 0.16 deprecated the `@cImport`
  language builtin; use `b.addTranslateC(...)` in `build.zig` and link the C library
  on that step instead of source-level `@cImport`):
  - `librtlsdr` (Phase 2 USB source).
  - `miniaudio` (single-header C) for playback, pinned in `build.zig.zon` and fetched
    by the package manager (hash-locked, not committed). A small C shim (`c/audio_shim.*`)
    wraps it so Zig only translates the clean shim API, never miniaudio's nested
    anonymous structs.
  - An FFT for survey mode: vendor a small C FFT (kissfft/pocketfft) translated via the
    build system, OR implement a radix-2 FFT in Zig.
- **liquid-dsp is OPT-IN, not required.** There is no usable Zig binding (the repo
  named `zig-liquid-dsp` is just a fork of the C library with no Zig in it). If
  pulled in later for the Costas loop, arbitrary-rate resampler (`msresamp_crcf`),
  or FEC, use a thin **C shim** to avoid passing C99 `float complex` by value across
  the FFI boundary (Zig has no first-class complex; translate-c handling of
  `_Complex` is fragile). Example shim pattern:

  ```c
  // liquid_shim.c
  #include <liquid/liquid.h>
  void nco_mix_up_f(nco_crcf q, float xr, float xi, float* yr, float* yi) {
      float complex y;
      nco_crcf_mix_up(q, xr + _Complex_I*xi, &y);
      *yr = crealf(y); *yi = cimagf(y);
  }
  ```

  Link liquid as a system library on the build step (`translate_c.linkSystemLibrary(
  "liquid", .{})`, or `exe.linkSystemLibrary("liquid")`) for dev; only vendor+compile
  its sources if cross-compiling needs it (it uses autotools and a generated
  `config.h`, so this is non-trivial — defer it).

---

## 11. Testing

- **Develop against recorded IQ from the start.** Capture once with
  `rtl_sdr -f 89.9M -s 1024000 -n 30720000 capture.cu8` (≈30 s) and iterate the
  whole DSP offline. Only go live when it already works on the file.
- Unit-test the DSP primitives against synthetic signals: feed a known FM-modulated
  tone through the discriminator and assert the recovered tone; feed a known DSB
  signal through the AM path; verify the de-emphasis IIR's frequency response matches
  the expected 150 µs / 75 µs rolloff.
- For survey mode, build synthetic MPX composites (known pilot + known FM and AM
  subcarriers at known SNR) and assert correct classification.

---

## 12. Reference constants

| Thing                         | Value                          |
|-------------------------------|--------------------------------|
| SCA subcarrier #1             | 67 kHz                         |
| SCA subcarrier #2             | 92 kHz                         |
| RDS                           | 57 kHz                         |
| Stereo pilot                  | 19 kHz                         |
| SCA de-emphasis (default)     | 150 µs                         |
| Main-channel de-emphasis      | 75 µs (US)                     |
| Typical SCA injection         | ~10% of modulation             |
| Typical SCA audio bandwidth   | ~5 kHz (voice/reading service) |
| Default RTL sample rate       | 1.024 Msps                     |
| Min MPX rate before extract   | ~240 ksps (256 ksps used)      |
| Default audio output rate     | 16 ksps                        |
