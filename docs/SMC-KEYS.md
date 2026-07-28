# SMC Keys — the living map

What Ice Cube knows about Apple's undocumented SMC keys, including field
findings from real hardware. Additions welcome (attach a diagnostics JSON).

## Fan keys (Apple Silicon)

| Key | Meaning | Type | Notes |
| --- | --- | --- | --- |
| `FNum` | fan count | `ui8` | 0 on fanless Macs (Air) |
| `F{i}Ac` | actual RPM | `flt` | little-endian float32 |
| `F{i}Tg` | target RPM | `flt` | write; **never write 0** (see below) |
| `F{i}Mn` / `F{i}Mx` | min/max RPM | `flt` | **advisory only** — firmware accepts values outside them, incl. 0. Software must clamp. |
| `F{i}Md` / `F{i}md` | fan mode | `ui8` | 0 auto · 1 forced · 3 system (thermalmonitord). Casing varies: lowercase on M5+. **Survives sleep** — see below. |
| `Ftst` | thermal-test unlock | `ui8` | M3/M4: mode writes fail (result 0x82) until `Ftst=1`, then retry for seconds. Absent on M5 — **and on Mac14,9**. |
| `F{i}ID` | fan descriptor | `{fds` | name field at bytes 4…15; often absent on AS |
| `#KEY` | total key count | `ui32` | powers enumeration (command 8) |

### Write sequence (what actually works)

1. Probe mode-key casing (`F0Md` vs `F0md`) once per machine.
2. Write mode 1. On firmware result `0x82`: write `Ftst=1`, wait ~3 s, retry
   mode 1 at 100 ms intervals (≤10 s).
3. Write `F{i}Tg` (float32 LE). **Verify by read-back** — IOKit returns
   success even when firmware rejects; check the SMCParamStruct result byte
   on every call.
4. Release: park `Tg` at `Mn` **first**, then mode 0, then attempt mode 3,
   then `Ftst=0` (if used), then close the SMC connection.

### `F{i}Md` survives sleep (Mac14,9 — 2026-07-28)

A written mode value is **not** cleared when the Mac sleeps. The SMC stays
powered and keeps honouring `F{i}Md = 1` with whatever `F{i}Tg` was last
commanded, so fans left forced at sleep entry keep spinning — while nothing of
the daemon's runs to notice, because the SoC is off.

Evidenced from the owner's own logs: a curve engaged at 18:16:39, `Clamshell
Sleep` at 18:21:47, then **994 seconds** of forced fans and total daemon silence,
released only when an unrelated 2-second Power Nap dark wake happened to run one
tick. This is the whole reason the daemon registers for IOKit power
notifications and hands the fans back before acknowledging sleep (PLAN.md
§4.3.6).

`Ftst` does not rescue this and never could: it is an *unlock* flag, so clearing
it re-locks future writes rather than releasing a fan already forced. On this
machine it is moot anyway — **`Ftst` is not among Mac14,9's 2169 keys** (dumped
with `icecube-diag --json`; only lowercase `ft00`…`ftG1` sensor keys exist), so
the `.ftst` unlock branch is unreachable here and cannot be exercised by the
owner at all.

### Field findings (Mac14,9, macOS 26.4.1 — 2026-07-23)

- The reference release sequence ("mode 0 + Tg 0") left both fans **stopped
  at 0 RPM indefinitely**; thermalmonitord did not reclaim them even as die
  temps passed 90 °C. Hence: never write Tg 0; park at `Mn`; hand back with
  mode 3; drop the SMC connection; and *still* keep watching (Ice Cube's
  guardian drives the fans itself if macOS stays absent).
- Reads need no privileges; **all** fan-key writes need root
  (`kIOReturnNotPrivileged` = `0xE00002C1` — beware docs citing `…C2`,
  that's `kIOReturnBadArgument`).
- Mac14,9 reports `F{i}Mn` 2317 / `F{i}Mx` 6800 for both fans, and idles
  fanless (0 RPM in mode 3 is normal when cool).

## Temperature keys

Die-class prefixes (higher legit temps): `Tp` (CPU), `Tg` (GPU), `Te`, `Tf`,
`Tc`. Plausibility filter: 10 < °C < 120.

### M2 generation (Mac14,x — curated, verified on Mac14,9)

CPU P-cores `Tp01 Tp05 Tp09 Tp0D Tp0X Tp0b Tp0f Tp0j` · CPU E-cores
`Tp1h Tp1t Tp1p Tp1l` · GPU `Tg0f Tg0j` · airflow `TaLP TaRF` · SSD `TH0x` ·
battery `TB1T TB2T` · wireless `TW0P`.

Sources disagree on some M2 P-core labels (Stats vs smctemp) — which is why
the diagnostics pipeline exists. Unknown models fall back to enumerating all
`T***` keys of type `flt` with plausible values, labeled by key.

### Other generations (per references, uncurated)

M1: `Tp*/Tg0*` · M3: `Te0*/Tf*` · M4: `Te0*/Tp0*/Tm*p` · M5: `Tp0*/Tg0-1*`.
Curating these needs diagnostics reports from real machines.
