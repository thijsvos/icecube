# README images

Fixed filenames — `README.md` links to these paths, so keep the names.

| File | Where it appears | How to capture |
| --- | --- | --- |
| `popover.png` | Hero, under the intro | Click the menu-bar icon. Capture with ⌘⇧4 then **Space**, then click the popover. |
| `curve-editor.png` | End of Features | Popover → **Curves…** |
| `setup.png` | Install → First run | Popover → Settings… → Fan Control → **Set Up…** |
| `sensors.png` | Supporting a new Mac model | Popover → **Sensors…** |

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
