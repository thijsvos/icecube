# The away preset — cooling harder while nobody can hear it

Ice Cube can switch to a preset of your choice when you step away from the
Mac, and put your own preset back the moment you return. It is **off until you
turn it on**, in Settings → Fan Control → *Switch presets while I'm away*.

## The idea

Fan noise is a cost only while someone is in the room. Every fan tool — Ice
Cube included, until now — ignores that: the preset you chose at the keyboard
keeps running after you lock the screen and leave, so an export, a build, a
download or a backup left to finish runs exactly as quiet, and exactly as warm,
as it did while you were watching it.

The away preset lets you pay for cooling in the currency you have plenty of
while you are gone. Lock the Mac, or let the display sleep, and the fans move
to the preset you named for those hours — Cold by default. Come back, and the
preset you had is running again before you have sat down.

## What counts as "away"

Any one of three things, all decided by macOS rather than by Ice Cube:

- the screen is locked (⌃⌘Q, the lock-screen menu item, or a password prompt
  after the display slept);
- the screensaver is running;
- the display is asleep.

You are "back" the moment none of them is true: an unlock, the screensaver
ending, or the display waking.

**There is deliberately no idle timer.** macOS already has one — the
display-sleep timer in System Settings → Lock Screen — and it knows things Ice
Cube does not: a film playing, a presentation, a screen share all keep the
display awake on purpose. A second timer inside Ice Cube would not know that,
and would spin the fans up twenty minutes into a movie. If you want "away after
ten minutes", set the display to sleep after ten minutes.

## What it puts back, and when it does not

Going away, Ice Cube remembers what was running. Coming back, it restores that
**only if the fans are still on what it set** — or on the daemon's resting
state, which is what a safety revert during sleep leaves behind and is nobody's
choice. If anything else picked a preset in between, that choice stands:

- **You plug in or unplug while away.** The away preset keeps holding; the
  power rule's choice is noted, and it is what you come back to. So *on
  battery use Quiet* and *while away run Cold* compose the way you would
  expect: Cold until you return, Quiet after.
- **You pick a preset by hand** in the first second after unlocking, before
  Ice Cube has noticed you. Yours wins.
- **Manual (fixed-RPM) mode** is left alone in both directions. A pinned fan
  speed is your explicit, hands-on choice; no automation in Ice Cube may put
  the fans under fixed-RPM control, and this one will not take them out of it
  either.
- **Nothing known to hand back** — the app has not applied a curve yet and
  the daemon is not running one. Then leaving does nothing, because a
  departure that could not promise a return would strand you on the away
  preset.

Like the power rule, it acts **on the change**, never continuously. The
question it answers is only ever "did the user just leave, or just come back?"
— never "what should be running?" — so it cannot end up fighting you.

## The science, in this Mac's own numbers

Whether more fan speed buys anything depends on how much the die rises per watt
at each speed. That is the quantity Ice Cube already measures for
[cooling efficiency](THERMAL.md), and the reference Mac14,9 gave these rows:

| Fans (RPM) | R (°C per watt above the intake air) |
| --- | --- |
| 3550 | **1.04–1.13** |
| 5950 | **0.89–0.93** |

Roughly 20 % better heat transfer for a 68 % increase in fan speed. For a
40 W job left running — an export, a long compile — that is the difference
between settling about **43 °C** above the air coming in and about **36 °C**
above it: some 7 °C cooler, from arithmetic on the rows above rather than a
new measurement. THERMAL.md's own caveat carries over: the low-speed rows sit
near the 5 W floor where the ratio is noisier, and a cooler die also leaks
less, so part of the gap is the chip rather than the fans. Treat it as the
size of the effect, not a promise of the number.

There is a second, quieter benefit. Cooling History only records settled
readings, and at the fan speeds a quiet preset runs the machine rarely settles
under real load. Hours spent away on a harder preset are hours of settled
readings in bands the history rarely sees — exactly the bands the forecast's
"running the fans harder would…" line refuses on today. Ice Cube gets a little
better at answering that question every time you go for lunch.

## What it is not

- **Not a health feature.** It changes nothing about what the cooling history
  or the °C/W index report; it only changes which preset runs.
- **Nothing while the Mac is asleep.** The daemon parks the fans before every
  sleep exactly as it always has. The away preset matters in the window before
  sleep, and whenever sleep is prevented — a job holding the Mac awake, or a
  Mac on power with an external display and the lid closed.
- **Nothing at true idle.** Once a Mac has cooled to its floor every preset
  sits at the same minimum fan speed. The effect is during the cool-down after
  you leave, and for as long as something is still drawing power.
- **No throttling claim.** Whether a cooler die on this Mac runs a long job
  faster has not been measured here, so it is not asserted.

## Limits

- An app that keeps the display awake on purpose (a movie, a screen share)
  never lets the display sleep, so on those evenings only locking the screen
  counts as leaving. That is the correct behaviour, and it is the reason there
  is no timer.
- The lock and screensaver notifications (`com.apple.screenIsLocked`,
  `com.apple.screensaver.didstart`) are not in a public header, though macOS
  has posted them under those names since 10.5. If Apple ever stopped, the
  feature would degrade to display sleep alone rather than misfire.
- It is app-side, like the power rule. With Ice Cube closed and a persisted
  curve running, nothing leaves and nothing returns.

Measured on the reference Mac14,9 (2026-09-02): locking the screen had the
fans on Cold **624 ms** later; unlocking had Balanced back within 1.3 s.

## Checking it did what it says

The user is, by definition, not looking while it acts. So the Settings pane
keeps one line under the rule that reads, after a trip, like:

> Last time you were away (14:02–14:31, screen locked) Ice Cube ran Cold and
> put Balanced back.

The unified log carries the same story with the daemon's own lines alongside:

```
presence: present -> away (screen locked)
away (screen locked): switching to Cold
curve engaged (persists without app: false)
presence: away -> present (here)
back: restoring Balanced
```

To watch it without a lock screen, a simulated run can script one trip:

```
ICECUBE_SIMULATED=1 ICECUBE_SIMULATED_PRESENCE=away-after:20 "/Applications/Ice Cube.app/Contents/MacOS/Ice Cube"
```

The user "leaves" 20 s after launch and "returns" 20 s later. Scripting a trip
also switches the rule on for that run — a simulated run's preferences start
empty and never touch the real ones — so the simulated daemon receives the away
preset and the hand-back, and nothing real moves. A simulated run logs under
its own subsystem, so the real log stays clean:

```
log show --last 2m --predicate 'subsystem == "io.github.thijsvos.icecube.tests"'
```
