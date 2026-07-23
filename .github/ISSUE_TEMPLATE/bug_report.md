---
name: Bug report
about: Something misbehaves
labels: bug
---

**What happened / what did you expect?**

**Steps to reproduce**

1.

**Environment**
- Mac model (About This Mac → Model Identifier, e.g. `Mac14,9`):
- macOS version:
- Ice Cube version (Settings… → Updates):
- Helper status line (Settings… → Helper daemon):

**Logs (if fan control is involved)**
```
log show --last 10m --info --predicate 'subsystem == "io.github.thijsvos.icecube"'
```
(Daemon-side entries may need `sudo`.) Paste the relevant lines:
