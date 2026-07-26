---
name: New Mac model report
about: Your Mac shows few/odd sensors, or fan control misbehaves on your SoC generation
labels: new-model
---

**Mac model identifier** (About This Mac → Model Identifier):

**What works / what doesn't** (monitoring? sensor labels? manual control? curves?):

**Diagnostics JSON** — this is the important part:
Ice Cube popover → **Sensors…** → **Export Diagnostics…**, attach the file here.

Exporting from the app runs a **write-path check** first and includes the result
(`writePath` in the JSON): whether the fans could actually be driven, which
mode key your generation uses (`Md` vs `md`), and whether your firmware needed
the `Ftst` unlock. That is the part that says how to support your Mac — the
sensor dump alone only describes reads. The check writes each fan's current
target back to itself, so nothing changes speed.

(From a checkout: `cd IceCubeKit && swift run icecube-diag --json > diagnostics.json`
— that path has no daemon, so it cannot include the write-path result.)

The report contains your Mac's SMC key catalog and sensor values — no
personal data beyond the hardware model.
