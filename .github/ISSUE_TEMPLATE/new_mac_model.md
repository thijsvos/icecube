---
name: New Mac model report
about: Your Mac shows few/odd sensors, or fan control misbehaves on your SoC generation
labels: new-model
---

**Mac model identifier** (About This Mac → Model Identifier):

**What works / what doesn't** (monitoring? sensor labels? manual control? curves?):

**Diagnostics JSON** — this is the important part:
Ice Cube popover → **Sensors…** → **Export Diagnostics…**, attach the file here.
(Or from a checkout: `cd IceCubeKit && swift run icecube-diag --json > diagnostics.json`.)

The report contains your Mac's SMC key catalog and sensor values — no
personal data beyond the hardware model.
