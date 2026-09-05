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

## How fast this Mac heats

`R` says where the die ends up. It says nothing about *when*, and "you are at
79 °C" is a much less useful sentence than "you are heading for 91 °C, about two
minutes out".

The missing term is the **thermal time constant**, τ. A cooling path behaves as
a first-order lag:

```
ΔT(t) = ΔT∞ + (ΔT₀ − ΔT∞) · e^(−t/τ)
```

### Measured on a Mac14,9

`swift run icecube-diag --forecast 1800`, 28 minutes of ordinary use,
89 accepted estimates:

| p10 | p25 | **p50** | p75 | p90 |
| --- | --- | --- | --- | --- |
| 38.6 s | 49.0 s | **73.7 s** | 130.4 s | 207.8 s |

Predicted beforehand from `R ≈ 0.9 °C/W` and a heatsink assembly of order
50–150 J/°C: `τ = R·C` ≈ 45–135 s. The measurement landed near the middle of
that, which is the rare case of a first-principles estimate surviving contact
with hardware.

**The answer is stable well before it is precise.** From the 23rd accepted
estimate onward the reported median stayed within **68–75 s** across the next
sixteen minutes — a 7 °C-equivalent spread of 7 seconds — which is why twenty
estimates is the bar. About 5 % of samples are accepted in ordinary use, so the
first answer arrives roughly twelve minutes after the app starts.

### Why it is measured from the transients `R` throws away

The settle rule rejects every sample where the die is still moving, and it is
right to: a quotient taken mid-ramp describes neither the old state nor the new
one. The 1.89 °C/W reading above is the example this file already keeps.

But the ramp is the **only** place τ exists. A machine that has settled has no
rate left to measure. So the same stream is read twice, for opposite reasons —
`R` waits for the machine to stop moving, τ waits for it to start.

### Three samples, not a rate of change

τ is measured from three equally spaced readings rather than a derivative. For
any first-order approach the ratio of successive differences is `e^(−h/τ)`, so
the destination cancels:

```
(ΔT₂ − ΔT₁) / (ΔT₁ − ΔT₀) = e^(−h/τ)      ⇒      τ = −h / ln(ratio)
```

Two consequences worth stating. It works identically whether the die is rising
or falling. And a **proportional** movement in the airflow reference cancels
too — airflow rises *with* the die rather than independently, which scales `ΔT`
by a constant, and a ratio is blind to constant scale.

### The spacing chooses which pole you measure

A laptop is not really first-order. Silicon responds to the heat spreader in
seconds; the spreader, heatsink and chassis respond in minutes. Fitting one
pole to that lands wherever the sampling window looks.

Swept against the simulation, whose poles are 6 s and 75 s:

| Spacing | p50 recovered |
| --- | --- |
| 10 s | 31.1 s |
| 30 s | 40.6 s |
| 60 s | 56.7 s |
| **90 s** | **80.7 s** |

Ice Cube samples at 90 s, because a forecast about the next few minutes is a
claim about the slow pole. Ten seconds was not measuring anything *wrong* — it
was measuring the die's own fast response, which is a different question from
the one being asked.

The cost is a triple spanning 180 s that the machine must hold steady
throughout, which is why most samples are refused.

### What the forecast is honest about

- **One pole fitted to two.** Optimistic about the first few seconds of a load
  step, accurate after.
- **Airflow treated as fixed** over the horizon. Over two minutes a 2 °C rise in
  the reference is a 2 °C error.
- **Nothing past half an hour.** Beyond that the inputs have almost certainly
  changed, and a figure with hours on it reads as precision the model has not
  got.
- **It never commands the fans.** The forecast is text. Letting a learned model
  spin cooling up pre-emptively is a different feature with a different risk.

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
- **Not a prediction.** `R` describes the state it was measured in. Ice Cube
  *can* now forecast — see "How fast this Mac heats" below — but that is a
  separate claim, built on a separate measurement, and it refuses far more
  often than `R` does. Nothing in this section becomes a forecast; the two are
  kept apart on screen for the same reason they are kept apart here.
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

How much of that is the charging itself, measured across four states on the same
machine on the same day:

| State | System power | Warmest cell |
|---|---|---|
| On battery, discharging | 26.4 W | **24.4 °C** |
| Plugged in, **charged**, idle | ~28 W | 32.0 °C |
| Charging, 100 % (finishing) | — | 34.8 °C |
| Charging, 55 % | 11.1 W | **36.2 °C** |

**Compare the first and last rows.** The machine was doing *more than twice the
work* while discharging, and its cells were **12 °C cooler**. Battery
temperature does not track workload at all — it tracks whether current is moving
through the cells. That is the whole premise of the charging explanation in *Why
is it hot?*, and it is hard to demonstrate more starkly than that.

Two other things fall out of the table.

Charging is worth roughly **4 °C** at the cells over sitting plugged in and
full. Small as a number, plainly noticeable as a surface — which is the point of
this section, and the reason Ice Cube reads `kIOPSIsChargingKey` rather than
settling for "on wall power". Row two is plugged in too, and has nothing to
explain.

And **being plugged in at all is worth about 7.5 °C** before any charging
happens (24.4 → 32.0 °C). The battery is full in both cases; the difference is
the charger circuitry and running the machine from AC. So "warm because plugged
in" and "warm because charging" are genuinely different magnitudes stacked on
each other, and Ice Cube only claims the second.

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

## Running it backwards

Everything above runs the model **forwards**: given the curve the user drew,
where does this load settle? `ThermalForecast` answers that on a two-second
tick and puts a sentence in the Diagnose window.

The opposite question was answerable the whole time and nobody had asked it.

```
forwards:   curve + load           →  settling temperature
backwards:  settling temperature + load  →  the fan speed that holds it
```

The second line **is a curve point.** A `FanCurve` maps die temperature to fan
speed; a fitted band maps load to a die temperature at one fan speed. So
`(ambient + band.rise(atWatts:), band.medianFanFraction)` is a point this
machine has *demonstrated*: run the fans there under that load and it sits
there. Sweep the load range, take the slowest band that still holds the target
at each step, and you have the quietest curve the evidence supports.

That is `CurveDerivation`, behind **Settings → General → Experimental → Made to
measure**. It draws every measured band as a bar in the curve editor's own
coordinates — at that fan speed, across the temperatures it was measured at —
and offers a curve fitted to them.

### The cliff, and why the curve is capped at 0.05 per °C

The first version was correct and useless. "The quietest fan speed that holds
the target" is a *hard cap*, and the optimal answer to a hard cap is bang-bang.
Against the simulated plant at a target of 80 °C the raw sweep produced:

```
(78.4 °C, 5 %)  (79.0 °C, 85 %)
```

Eighty percentage points of fan across **0.6 °C**. `CurveFollower` carries a
4 °C hysteresis deadband, so that curve is a step function that hunts — and
the discrete band search downstream could not find a self-consistent band
inside it either, reporting settling points up to 20 °C above the truth.

The escape is that the sweep produces a **lower bound**, not a prescription:
any curve at or above it holds the target. So the steepness is capped at 0.05
per °C — floor to full in 20 °C — and paid for by starting the ramp earlier.
That is more fan at cooler temperatures and never less, which keeps the promise
intact. For scale the shipped presets ramp at 0.025 (Balanced), 0.033 (Quiet)
and 0.0147 (Cold's steepest segment).

With the cap in place the forward solver and the plant agree to within 0.5 °C
at every load in the sweep, where before they differed by up to 20.

### What it refuses

The same three things the rest of this file refuses, for the same reasons.

- **One measured fan speed is not a comparison.** What a faster fan buys is
  exactly the thing a single-band machine has never shown. Two bands minimum.
- **A hole in the load coverage contributes no point.** `Band.covers(watts:)`
  still governs; the failure it was written for — an idle band's line
  extrapolated to 48 W advising *slower* fans — is the same failure seen from
  the other side, and it would be baked into a curve rather than shown in a row.
- **Past the evidence there is no fitted answer.** The curve does not
  extrapolate. It ramps to full fans by 94 °C, ten degrees under the ceiling
  the daemon enforces. That anchor is the one point in a derived curve that is
  not a measurement, and it is deliberately the safe direction.

### The finding worth the feature

On the reference machine, sweeping load at a target of 85 °C:

| Load | Slowest fan speed that holds 85 °C | Settles at |
| --- | --- | --- |
| 25 W | fan minimum | 55 °C |
| 35 W | fan minimum | 77 °C |
| 45 W | ~64 % | 85 °C |
| 52 W | **full — and still 87 °C** | 87 °C |

The last row is the point. At this Mac's measured peak draw, *even full fans*
land above 85 °C, so the request is not available on this hardware — and the
panel says so, in those terms, rather than handing over a curve that quietly
misses. No fan tool has told anyone the actual thermal limit of the laptop in
front of them, because none of them measured it.

### What it is still not

A vote on the cooling. The rule above stands: a model that has never run on
hardware does not get to spin the fans. This produces **points in an editor**
that a person drags, judges and applies, and every clamp, ceiling and watchdog
in the daemon sits under a derived curve exactly as it sits under a hand-drawn
one. The distance between a proposal and a command is the whole design.

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
