# rtl-sca — Guide

Detailed usage and operating notes. For a 30-second start, see the
[README](README.md); for *why* the signal chain is built the way it is, see
[`SPEC.md`](SPEC.md). Running `rtl-sca` with no command prints the terse flag list;
this document is the prose behind it.

## Commands

- **`scan <input>`** — survey the FM MPX baseband and print a **uniform inventory** of
  every component as a table row (center · type · bandwidth · strength · role): the
  0 kHz main program (L+R), the 19 kHz pilot, the 38 kHz stereo L−R, 57 kHz RDS, and
  any 67/92 kHz audio SCAs. Use it to find what a station carries before decoding. The
  table goes to **stdout**; reads ~4 s and exits.

  Reading the table:
  - **Strength (SNR)** is each component's level over the local noise floor — a
    snapshot, not a fixed station property. Use it to rank targets (a 67 kHz SCA at
    +31 dB vs +10 dB).
  - **`0 kHz main program`** is the station-present anchor: a strong main channel with
    *no 19 kHz pilot row* is a real **mono** station (e.g. a talk station), not a dead
    channel. Stereo shows up as the **presence of the pilot row** — there's no separate
    "stereo: yes/no" line.
  - **The pilot vs the L−R.** The 19 kHz pilot is the *stable* stereo indicator (it's a
    constant tone). The 38 kHz L−R strength is the *live stereo separation* — it's the
    measured sideband energy, so it **drops to noise on mono program content** even
    though the pilot stays put. A low L−R with a strong pilot means "stereo station,
    mono content right now," not a fault.

  ```
  $ rtl-sca scan 89.9M
  slot      mod       bw         snr     guess
    0 kHz  -        ~15.0 kHz    16 dB  main program (L+R)
   19 kHz  tone     ~ 0.0 kHz    30 dB  stereo pilot
   38 kHz  am_dsb   ~30.0 kHz     8 dB  stereo subcarrier (L−R)
   57 kHz  data     ~ 3.1 kHz    12 dB  data subcarrier (RDS)
   67 kHz  fm       ~ 0.9 kHz    31 dB  audio SCA
  ```
- **`play <input> --sub HZ`** — demodulate one subcarrier and play it live out the
  default audio device. Runs until Ctrl-C.
- **`rec <input> --sub HZ -o FILE`** — same chain, written to a 16-bit mono WAV
  instead of the speakers. Ctrl-C finalizes the file.

## Sources

`<input>` is auto-detected:

- **Local RTL-SDR** (default) — give a frequency (`89.9M`, `89900000`). `--device N`
  selects among multiple dongles.
- **`rtl_tcp` server** — add `--remote host[:port]`; `<input>` is then the tune
  frequency. The host may be a literal IP (`192.168.1.50`) or a name resolved through
  the OS (DNS, `/etc/hosts`, mDNS); the port defaults to rtl_tcp's `1234`. Start the
  server with `rtl_tcp -a 0.0.0.0 -f <freq> -s 1024000`. **One client at a time** (see
  Operating notes).
- **Recorded IQ file** — any path that isn't a frequency (`capture.cu8`, `.cs16`).
  `--source PATH` forces the file interpretation (for a file whose name looks like a
  frequency).

Radio-only flags (`--gain`, `--ppm`, `--device`, `--remote`) are an error with a file
source.

## Subcarriers & bandwidth

- **`--sub HZ`** — the subcarrier center. Common SCAs sit at **67 kHz** and **92 kHz**;
  the 57 kHz slot is RDS (data), the 38 kHz slot is the stereo L−R. `--sub 0` selects
  the **main program channel**.
- **`--bw HZ`** — the *unique* bandwidth recovered, and the semantics differ by slot:
  - For a **subcarrier**, `--bw` is the **slot width** (±bw/2 around the slot). So
    `--bw 8k` at 67 kHz isolates a 8 kHz-wide slot and recovers **~4 kHz of audio**.
    To get more audio you widen the slot: a DSB-SC L−R that occupies ±15 kHz needs
    `--bw 30k`.
  - For the **main channel** (`--sub 0`), `--bw` is the **audio width** directly
    (`--bw 15k` → 15 kHz of mono audio).
  - The `play`/`rec` startup line prints the recovered audio bandwidth
    (`slot 8 kHz (audio ≤4.0 kHz)`) so you can see which you got.
- **Main channel (`--sub 0`)** recovers normal mono FM (L+R) from the 0 Hz baseband —
  no NCO, no second demod. It's a validation/utility mode: if the program is audible,
  the front-end and FM demod are proven before you chase a weak subcarrier. Use
  `--bw 15k --deemph 75us`. Mono only; stereo (L−R) decode is out of scope.

## Demodulation

- **`--mod MODE`** (default `fm`):
  - `fm` — narrowband FM. Most audio SCAs and the main channel.
  - `am-env` — envelope (incoherent) AM, for a carrier-present AM subcarrier.
  - `am-coherent` — synchronous AM via a Costas loop, for **suppressed-carrier
    DSB-SC** (the 38 kHz L−R, some SCAs). See the lock notes below.
- **`--deemph TAU`** — de-emphasis time constant, undoing the transmitter's
  pre-emphasis. It's a *continuous* value, not a fixed set: any number with an
  optional `us` suffix, or `off`. Standard values: **`150us`** (SCA, the default),
  **`75us`** (US main channel), **`50us`** (EU main channel).

## Output

- **`--audio-rate HZ`** — output sample rate; a rational resampler bridges the
  internal content rate to it. Live `play` defaults to the audio device's native
  rate (so our resampler owns the conversion, not the OS mixer); `rec` and files
  default to 48 kHz.
- **`--rate HZ`** — the RTL-SDR / recording IQ rate (default `1.024M`). Also applies
  to a file source (the recording's IQ rate).
- **`-o FILE`** (`rec`) — output WAV path. **`-o -`** streams the WAV to stdout; since
  a pipe isn't seekable, the header advertises an unknown length and players read to
  EOF.
- **Streams.** All diagnostics — the startup summary, errors, the rate plan, the
  `-v`/`-vv` lines — go to **stderr**. The `scan` results table and a `rec -o -` WAV
  go to **stdout**. So results pipe/redirect cleanly while diagnostics stay visible:
  ```sh
  rtl-sca scan 89.9M > slots.txt
  rtl-sca rec 89.9M --sub 67k -o - | aplay
  ```

## Diagnostics (`-v` / `-vv`)

`play`/`rec` always print a one-line **startup summary** to stderr (regardless of
`-v`): the source, the radio params fed to it, the demod, the recovered audio
bandwidth, and the destination.

`-v` adds, at exit:
- a **health** line — DSP speed vs. real time, USB sample drops, audio underruns
  (the "is the plumbing flowing?" view);
- a **signal** line — front-end level + clip %, Costas lock + carrier offset Δf (for
  `am-coherent`), output level + clip % (the "is the signal good?" view).

In `scan`, `-v` also prints the rate plan and per-slot classifier metrics.

`-vv` logs the health + signal lines **live** (~every 2 s), each windowed to that
interval (so a value reflects "now", not a lifetime average); the plumbing totals
stay cumulative.

**Reading the signal line:**
- **input clip %** is the front-end overload indicator. High → gain too high (the ADC
  is railing); ~0 with a very low level → gain too low. The input *dBFS* pins at
  `0.0` whenever *any* sample rails, so trust the **clip %**, not the peak.
- **output clip %** should be ~0 — the output gains are deviation-matched so peaks
  land just under full scale. Sustained output clipping means over-deviation or a
  real front-end overload.
- **lock / Δf** (am-coherent only): `lock` → 1 and `Δf` → ~0 Hz when the Costas loop
  catches the suppressed carrier; `lock` ≈ 0 with a large `Δf` means it's hunting.

## Operating notes

### Gain & overload
Gain is manual via `--gain` (auto by default). A strong local station can overload
the front-end badly — e.g. a station that clips **84 %** of input samples at gain 30
can be clean at gain 7. Watch the `-v` **input clip %** and drop the gain until it's
~0. Because the input dBFS saturates at `0.0` the moment anything rails, the clip %
is the real overload signal.

### Output level
Output gains are deviation-matched (main channel ≈ unity, subcarrier ≈ 0.5) so the
discriminator's radian-valued output lands just under ±1; the WAV/audio clamp is a
safety net for rare over-deviation. Voice/music has a ~13 dB crest factor, so a low
RMS with peaks near full scale is normal.

### Tune-in transient
The first ~0.3 s after a live (re)tune is front-end overload while the tuner PLL and
gain settle — the discriminator outputs garbage (measured: input clip 60 %→0 over
~180 ms). rtl-sca **drops** that window on live sources, so a recording starts at the
first real audio with no leading silence. A *later* overload is deliberately left
audible — it's a real problem worth hearing, and the input clip % surfaces it.

### Stereo L−R (am-coherent)
The 38 kHz L−R is DSB-SC and only exists when the program has stereo separation — it
**vanishes during mono content**, leaving the Costas loop nothing to lock to (`lock`
≈ 0, `Δf` wanders). When real stereo is present and the front-end isn't overloading,
it locks cleanly (`lock` ~0.7, `Δf` ~0 Hz). It's a blind Costas loop, not a
pilot-regenerated 38 kHz, so it works best on strong, continuously-stereo signals.
Stereo decode is otherwise out of scope.

### rtl_tcp behavior
`rtl_tcp` serves **one client at a time**, and a fresh connection streams at real
time. If the client *stalls*, the server buffers the backlog (effectively unbounded
— an 18 s stall buffers ~18 s), and the client drains it at ~5× real time on resume.
`play` is self-limiting (paced by the audio device through a small ring, so it
backpressures the socket and can't run ahead); `rec` has no real-time consumer, so
after a stall it drains the buffered — and now slightly stale — audio as fast as the
DSP runs. A mid-stream disconnect (server restart, network blip) is treated as a
clean end of stream: the recording is finalized and the program exits 0.

### Error messages
Runtime errors state the operation and the concrete identifier, nothing more:
`connection refused: pi4:1234`, `could not resolve host: pi4`, `input file not found:
capture.cu8`, `lost the rtl_tcp stream from pi4:1234`.
