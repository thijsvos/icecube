# README images

Fixed filenames — `README.md` links to these paths, so keep the names.

| File | Where it appears | How to capture |
| --- | --- | --- |
| `popover.png` | Hero, under the intro | Click the menu-bar icon. Capture with ⌘⇧4 then **Space**, then click the popover. |
| `curve-editor.png` | End of Features | Popover → **Curves…** |
| `sensors.png` | Supporting a new Mac model | Popover → **Sensors…** — **due a retake**: the current shot predates content-sized sizing and shows the old fixed 560×480 window with its list scrolled. Grab it at the window's natural height. |
| `first-run.png` | Install → First run | Only visible while fan control is **off** (Settings → Turn Off Fan Control). The popover then shows "Fan control is off" with the setup button. |

Not currently linked from `README.md`:

- `setup.png` — the setup *window* itself (the "Turn on fan control" step),
  which would sit alongside `first-run.png`. Optional: `first-run.png`
  already carries that section. There is **no way to open it while fan
  control is enabled**: Settings shows "Reinstall"
  in that slot, and the popover only offers a setup prompt when the helper is
  missing or version-mismatched. Take it during a clean-machine install test
  rather than unregistering a working daemon to stage it, and add the `<img>`
  back to README.md when you do.

Guidance:

- **⌘⇧4 then Space** captures a window with its drop shadow and rounded
  corners on a transparent background. Plain ⌘⇧4 drag does not.
- Retina (@2x) is correct — GitHub scales it down. Keep each file under
  ~500 KB.
- The popover shot catches the menu bar behind it: check for anything you
  would rather not publish (network name, other apps, calendar titles).
- Dark only is fine, and matches the app's dark-first design. If light
  variants are ever added, GitHub honours `<picture>` with
  `prefers-color-scheme`.
- Use **real** data for `popover.png` — run a build or an export first so the
  charts show activity. Idle flatlines undersell the app badly. Simulated
  mode (`ICECUBE_SIMULATED=1`) is fine for the curve editor and sensors.
- `cooling-history.png` — **not yet captured.** The Cooling History window
  under `ICECUBE_SIMULATED=1 ICECUBE_SIMULATED_HISTORY=rising`, which seeds
  months of physically-correct data (the medians come from THERMAL.md's
  measured table; a *live* simulated recording would slope backwards). Not
  linked from README.md until it exists.
