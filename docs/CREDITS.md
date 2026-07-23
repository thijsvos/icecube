# Credits & prior art

Ice Cube's code is original (MIT), but it stands on community research:

- **[exelban/Stats](https://github.com/exelban/stats)** (MIT) — the best
  real-world SMC key maps per SoC generation, and the reference for the
  Apple Silicon fan-control sequence including the `Ftst` unlock
  (issue #2928 / PR #2924). Our M2 sensor map is seeded from its tables.
- **[agoodkind/macos-smc-fan](https://github.com/agoodkind/macos-smc-fan)**
  (MIT) — meticulous per-generation write-path research (M1→M5): mode-3
  semantics, `Ftst`, error codes, privilege model, sleep/wake resets.
- **[beltex/SMCKit](https://github.com/beltex/SMCKit)** (MIT) — the classic
  `SMCParamStruct` layout reference (our 80-byte ABI mirrors it, including
  the explicit padding after `keyInfo`).
- **[narugit/smctemp](https://github.com/narugit/smctemp)** — cross-check for
  M2 sensor keys and the 10–120 °C plausibility bounds.
- **smcFanControl** (GPL) — historical concepts only; no code was read into
  this project's implementation.
- Apple TN3127 (code-signing requirement strings) and Quinn "The Eskimo!"'s
  SMAppService guidance shaped the XPC pinning and daemon registration.
