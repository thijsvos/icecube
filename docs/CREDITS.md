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

## Artwork

- **The Inside schematic** is drawn from scratch, and deliberately so. Apple
  publishes Self Service Repair manuals with exploded views, and iFixit
  publishes teardowns, but neither is licensable here: Apple's manuals are
  copyrighted, and iFixit's CC BY-NC-SA carries a NonCommercial clause this
  project's MIT licence cannot accept. What the drawing uses instead is
  *general arrangement* — a fact, not an expression: every Mac laptop cools
  with centrifugal blowers that draw air in through a central inlet and vent
  through a volute into a fin stack at the hinge. Nothing is traced, and the
  window says in its own footnote that it is a schematic rather than a map of
  any particular board.
- **App icon & menu-bar glyph**: the 🧊 "Ice" emoji (U+1F9CA) from
  **[Google Noto Emoji](https://github.com/googlefonts/noto-emoji)**,
  licensed **Apache 2.0**. Composited onto Ice Cube's gradient background and
  rescaled. Copyright © Google Inc. See `art/README.md`.
