# Cooling efficiency — what °C/W means, and what it does not

Ice Cube shows a number called **cooling efficiency**, in degrees Celsius per
watt. This file explains what it is, how it is computed, why each constant has
the value it does, and — as importantly — the things it cannot tell you.

Every figure in the measurements table was taken on real hardware. Where
something has not been measured, the table says so rather than guessing.

## The problem it solves

Ice Cube already shows temperature and fan speed. Neither answers the question
you actually have when a Mac is hot:

> Is it hot because it is working hard, or because its cooling is failing?

Those look identical on a temperature graph. 95 °C while exporting video is a
Mac doing its job. 95 °C sitting idle is blocked vents, dried thermal paste, or
a fan that has stopped. The missing term is **power** — how much heat is going
in — and once you have it the two cases separate cleanly.

## The physics

At steady state, the heat going into a chip equals the heat leaving it. The
temperature rise above the surrounding air is proportional to the power being
dissipated:

```
ΔT = P × R
```

Rearranged, that gives a property of the *cooling system* rather than of the
workload:

```
R = (T_die − T_ambient) / P          °C per watt
```

That is the form heatsinks are specified in, and it is why the number is
comparable to itself over time when raw temperature is not: 70 °C means different
things at 10 W and 50 W, and dividing by power removes the workload.

**One honest qualification, up front.** `P` here is *system* power, not the power
dissipated by the die whose temperature is in the numerator. So this is not
literally the chip's thermal resistance — some of those watts go to the display,
the SSD and charging losses, and never pass through the heatsink. What it is, is
a stable **cooling-efficiency index**: die rise per watt the machine draws. Every
use below survives that, because all of them compare the number to itself on one
machine. None of them survive treating it as a datasheet figure.

Three consequences follow, and they are the reason the number is worth showing:

1. **It should stay roughly constant as load changes**, at a fixed fan speed.
   Measured below.
2. **It falls as the fans spin faster** — which makes it a measurement of
   exactly what the noise is buying you.
3. **It rises as a machine ages.** Dust, dried paste and a failing bearing all
   reduce cooling, and they show up here before they show up as a temperature
   you would notice.

## How Ice Cube computes it

Source: `IceCubeKit/Sources/IceCubeKit/CoolingEfficiency.swift`.

- **`T_die`** — the hottest die-class sensor (CPU or GPU silicon). Classified by
  `SMCKeyMaps.classify`.
- **`T_ambient`** — the *coolest* airflow sensor (`TaLP`, `TaRF`). See the
  limits section: this is not room temperature.
- **`P`** — total **system** power, from the `PSTR` key (`PDTR` as fallback).
  [SMC-KEYS.md](SMC-KEYS.md) measured this as *system total*, not the SoC package
  alone. That matters and is dealt with under "What this number is not" — the
  first draft of this file called it SoC package power, which was wrong.

The arithmetic is one division. The discipline around it is the actual feature:
Ice Cube refuses to show a number more often than it shows one.

### The four refusals

| Rule | Constant | Why |
| --- | --- | --- |
| Any input not finite | — | A failed sensor read must never become a number. |
| Power below the floor | `minimumWatts = 5` | `R` is a quotient. As `P → 0` the noise in `ΔT` is amplified without bound: at 4 W a ±1 °C sensor wobble moves `R` by ±0.25 °C/W — larger than the difference between a clean Mac and a dusty one. |
| Die at or below ambient | — | Physically means nothing measurable is being dissipated; arithmetically would give zero or a negative resistance, which is not a thing. Happens for real at cold boot. |
| Not settled | `settleWindow = 20 s` | See below. |

### Why "settled" matters most

Silicon has thermal mass. When load jumps, the die keeps *absorbing* heat for a
while before it reaches a new equilibrium — so `ΔT` lags `P`, and during that lag
the quotient describes neither the old state nor the new one. It is a
meaningless number that looks exactly like a meaningful one.

So Ice Cube only reports `R` when, for a continuous 20 seconds:

- every sample is above the power floor,
- power stays within **15 %** (`powerTolerance`) of its mean,
- the die stays within **1.5 °C** (`temperatureToleranceCelsius`) of its mean.

Twenty seconds is twenty samples at the default 1 Hz cadence, and still four at
the slowest 5 s cadence a user can pick — which is why `minimumSamples` is 4
rather than 10. 1.5 °C is a little above
the SMC's own reporting granularity — a tighter bound would mean never settling.

A gap in the data **resets** the window rather than being skipped over. Stitching
the two sides of a hole together and calling the result steady is precisely the
lie the rule exists to prevent.

When the window is not settled the app shows `—`, never an estimate.

## Measurements — Mac14,9 (M2 Pro, 14-inch MacBook Pro), macOS 26.4

Taken 2026-08-02 with `icecube-diag`.

### Load invariance at a fixed fan speed

The central claim. Three readings at the same fan speed across a range of power:

| Fans (RPM) | Power (W) | Die (°C) | Airflow (°C) | R (°C/W) |
| --- | --- | --- | --- | --- |
| 5950 | 24.0 | 66.7 | 46.8 | **0.91** |
| 5950 | 21.5 | 65.7 | 46.8 | **0.93** |
| 5950 | 22.3 | 66.8 | 47.0 | **0.89** |

`R` varies by about **±2 %** across a 12 % spread in power. That is the
load-invariance property holding, and it is what makes the number worth
tracking over time.

### Fan-speed dependence — measured

`R` falls as the fans speed up. Two speeds, same machine, same session:

| Fans (RPM) | Power (W) | Die (°C) | Airflow (°C) | R (°C/W) |
| --- | --- | --- | --- | --- |
| 3550 | 9.0 | 53.1 | 44.7 | **1.04** |
| 3550 | 8.6 | 53.2 | 43.8 | **1.13** |
| 5950 | 21.5–24.0 | 65.7–66.8 | 46.8–47.0 | **0.89–0.93** |

Roughly **20 % better heat transfer for a 68 % increase in fan speed** — which is
the trade this app exists to let you make, in measured units.

Two honest caveats on the low-speed rows. They sit close to the 5 W power floor
(8.6–9.0 W), where the quotient is noisier — the two samples differ by 9 %, against
2 % at the high-speed end. And they are a *lower bound* on the effect: the die is
also cooler there, and silicon leaks less current when cool, so some of the
difference is the chip, not the fans.

**A third sample is worth recording because it is the settle rule earning its
keep.** Taken seconds after a cooldown ended, it read **1.89 °C/W** — while the die
was still falling from 57.9 °C to 53.1 °C. It is not a worse measurement of the
same thing; it is a measurement of nothing, and it looks identical to a real one.
`isSettled` is what stops that number reaching a user, and the figure above it in
this table is what it looks like once the machine has stopped moving.

Readings at Quiet and Max would extend the table further; contributions welcome
(see below).

### Idle draw

True idle on this machine measured **7.9 W** at 48.2 °C. Note this is well below
the 19.6 W that [SMC-KEYS.md](SMC-KEYS.md) records for `PSTR` "at idle" — that
figure was evidently captured with background work running. 7.9 W is close to
the 5 W floor, so a deeply idle Mac may legitimately show `—`.

## What this number is not

- **Not the chip's thermal resistance, despite the units.** The denominator is
  whole-system power (`PSTR`), not the heat crossing the die-to-air path. Treat
  the number as an index, not a datasheet value.
- **Not comparable between machines.** Two reasons now. The ambient reference is
  an airflow sensor *inside* the Mac, downstream of warm components, so it reads
  several degrees above the room. And the system-power denominator includes
  whatever else that particular Mac is powering — a second display changes it
  without anything thermal changing. Compare it to **your own past readings**.
- **Not a health score.** There is no threshold at which a value becomes "bad".
  What matters is the *trend on one machine at a comparable fan speed*.
- **Not a prediction.** It describes the state it was measured in.
- **Not affected by room temperature in the obvious way.** A hotter room raises
  the die *and* the airflow reference, so `R` moves less than you would expect —
  which is a feature, but it means `R` is not a proxy for how hot your room is.
- **Not a continuous record.** Ice Cube keeps history now (see below), but
  only of *settled* readings, and only while it is running — a persisted curve
  keeps driving the fans with the app closed, and nothing is recorded during
  those hours. Whole days can pass with nothing recorded. That is the settle
  rule working, not a gap in the data.

## Warm to the touch is a different scale from hot for the hardware

The two questions people ask — *"is my Mac too hot?"* and *"why does it feel
hot?"* — have different answers, and a Mac can be a firm **no** to the first
while being obviously **yes** to the second.

Skin sits at roughly **33 °C**. Whether a surface feels warm is not about its
temperature in isolation but about which way heat flows between it and your
hand. Below about 30 °C a surface draws heat *out* of your skin and reads as
cool. Around 33 °C the flow stops and it reads as neutral. Above that your hand
stops shedding heat, and the nervous system reports that as *warm* — long before
anything is thermally interesting to the machine.

Aluminium sharpens this. It conducts far better than plastic, so a metal case
reaches equilibrium with your palm almost immediately, while a plastic laptop at
the identical temperature feels milder. Unibody Macs feel hotter than their
numbers for a reason that has nothing to do with their cooling.

The gap this opens is wide. On a Mac14,9 charging, measured:

| | |
|---|---|
| Hottest die | 56 °C (limit 104 °C) |
| Battery cells | 34.8 / 33.9 °C (limit 95 °C) |
| Airflow | 39.9 / 38.8 °C |
| Fans | 5235 RPM |

How much of that is the charging itself, measured on the same machine:

| State | Warmest cell |
|---|---|
| Plugged in, **charged**, idle | 31.9 – 32.1 °C |
| Charging, 100 % (finishing) | 34.8 °C |
| Charging, 55 % | 36.2 °C |

So charging is worth about **3–4 °C** at the cells. Small as a number, and
plainly noticeable as a surface, which is the whole point of this section. It is
also why Ice Cube reads `kIOPSIsChargingKey` rather than settling for "on wall
power": the top row of that table is plugged in too, and has nothing to explain.

Every sensor is comfortable. The case is still *distinctly* warm, because the
34.8 °C battery spans the bottom of the machine and is the only one of those
surfaces a hand ever touches — while the 56 °C die is buried under a heatsink
nobody can reach.

**Two consequences worth knowing.**

The first is that a warm case during charging is expected. Charging dissipates
roughly 6–10 W in the cells and charging circuitry, spread over a large flat
area rather than concentrated on the chip, and it fades once the battery fills.
Ice Cube says so in *Why is it hot?* — the one cause it names outright, because
it is the one it reads rather than infers.

The second is that **raising the fans will not move that reading.** They pull
air across the heatsink and out through the hinge; the battery is not in that
path. In the measurement above the fans were already at 5235 RPM with the cells
still near 35 °C.

Read that narrowly, though — it is a fact about the battery, not about the
machine. The two warm places on a MacBook have different causes and different
remedies:

| You feel it | Source | Do the fans help? |
|---|---|---|
| Under the palms / bottom case | Battery, charging | **No** — not in the airflow path |
| Around the keyboard, space bar upward | SoC, under the deck | **Yes** — that is exactly what they cool |

Measured on the same Mac an hour later: 25–50 W of system power with the fans
at 2450 of 6800 RPM, the die at 58 °C, and the cells at a cool 31.9 °C. The
keyboard was warm and the palm rest was not. Same machine, opposite answer —
there the fans had enormous headroom and were the entire remedy.

Worth knowing before reaching for the fan curve: check *where* it is warm first.

## How to read it

At a **comparable fan speed**, on **your own machine**:

- A stable `R` over months means your cooling is unchanged.
- A slowly rising `R` means heat is having a harder time getting out: dust in
  the vents or on the fins is the usual cause, dried paste the next.
- A sudden jump means something changed abruptly — a fan that has stopped, or a
  vent that is blocked right now.

The fan speed caveat is not optional. `R` genuinely differs at 2300 RPM and
6800 RPM, so comparing a reading taken under Quiet with one taken under Max
tells you about the presets, not about your hardware.

## Tracking it over time

Since 2026-08-08 the degradation use case is real: Ice Cube persists settled
readings and the **Cooling History** window compares this machine with its own
past. Everything below is the small print that keeps that comparison honest.

### What is recorded

One record per settled stretch, at most one per five minutes — not one per
second: a Mac that idles quietly for ten minutes produces two readings with
their evidence attached, rather than six hundred copies of the same number.
The recording bar is deliberately **higher** than the display bar: at least
10 W (the 8.6–9.0 W rows above showed 9 % spread — a datum that noisy cannot
support a 10 % claim), a dense settle window, and fans that held one speed
through it, because fan speed is the axis every comparison is grouped by.

### Where it lives, and what is in it

`~/Library/Application Support/IceCube/cooling-history.json`, in the clear.
Each record holds when it was taken, the °C/W figure, the die, airflow and
watts it was computed from, and the fan speed. There is nothing in this file
that is about you: it is a record of how well one machine sheds heat, it never
leaves the Mac, and it is deliberately absent from the diagnostics export —
that file goes on public GitHub issues, and a months-long timestamp series is
a record of when a machine was in use. A salted hash (never the serial itself)
ties the file to this Mac, so a history that follows `~/Library` through
Migration Assistant onto a different machine is set aside rather than merged —
`R` is not comparable between machines, including a warranty replacement of
the same model.

### Retention

Raw readings live a week; day-by-day summaries (median, quartiles, count per
fan-speed band) live two years. If the summary cap ever binds, thinning starts
*after* the oldest ninety days — the oldest readings are the baseline, and a
history that evicts its own baseline first has thrown away the only thing it
was for. The file is bounded for life at well under a megabyte in ordinary
use.

### How the verdict is computed

Medians, never means — every way the settle rule can be fooled produces an
`R` that is too *high* (the 1.89 °C/W transient above), and a mean is dragged
in exactly the direction of the claim this feature most fears getting wrong.
The last 14 days are compared against the **earliest** qualifying 14-day
window at least 30 days back and at most a year old — earliest by rule, so
the baseline is a pre-specified choice rather than a search for a result —
and only within one fan-speed band: 1.04–1.13 °C/W at 3550 RPM against
0.89–0.93 at 5950 is a spread from fan speed alone larger than the
degradation being looked for, so Ice Cube will not average across bands to
produce an answer. A slow change is not called until it clears **10 %**
(~4× the measured noise); a one-day jump is not called until it clears 15 %
against the same band's own recent days. Anything less reports as steady or
as a refusal that names what is missing. **Mark as Cleaned** records a
boundary the baseline never spans, so a repaste does not read as
"improved" forever after.

### What it still cannot tell you

- **Why.** A rising trend reports that the number moved and by how much; dust
  is the usual cause at that pace and dried paste the next, but the app
  cannot see inside the machine and its copy never claims to.
- **The confounds.** A warmer room across the same months moves it a little.
  A change in what the machine powers moves it more: the denominator is
  whole-system watts, so a display *unplugged* since the baseline reads as
  "worse" and one *plugged in* reads as "better", without anything thermal
  changing. The window's hover text names the applicable one on every
  verdict.
- **Other Macs.** Unchanged from the limits above: the trend compares one
  machine with itself, ever.

The per-machine noise-value curve this file closes on — how much cooling a
given fan speed buys *on your Mac* — is now a matter of drawing it rather
than measuring it again: every record already carries the fan speed it was
taken at.

## Contributing a reading

The measurements above cover exactly one Mac. If you want to add yours:

1. `swift run icecube-diag` and note the model, power, die temperature, airflow
   temperature and fan RPM.
2. Let the machine sit at a steady load for a minute first — a reading taken
   mid-transient is not usable.
3. Open an issue with those numbers and the preset that was running.

Readings at several fan speeds on one machine are more useful than single
readings from many, because the interesting quantity is how much cooling a given
amount of noise buys — and that is a per-machine curve, not a single number.
