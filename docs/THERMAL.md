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

This is how heatsinks are specified, and it is the only number in Ice Cube that
is comparable to itself over time. Raw temperature is not: 70 °C means different
things at 10 W and 50 W. Dividing by power removes the workload and leaves the
cooling.

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
- **`P`** — total SoC package power, from the `PSTR` key (`PDTR` as fallback).
  Documented in [SMC-KEYS.md](SMC-KEYS.md).

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

Twenty seconds is ten polls at the default 1 Hz cadence. 1.5 °C is a little above
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

- **Not comparable between machines.** The ambient reference is an airflow
  sensor *inside* the Mac, downstream of warm components, so it reads several
  degrees above the room. Comparing your `R` to someone else's compares two
  different reference points. Compare it to **your own past readings**.
- **Not a health score.** There is no threshold at which a value becomes "bad".
  What matters is the *trend on one machine at a comparable fan speed*.
- **Not a prediction.** It describes the state it was measured in.
- **Not affected by room temperature in the obvious way.** A hotter room raises
  the die *and* the airflow reference, so `R` moves less than you would expect —
  which is a feature, but it means `R` is not a proxy for how hot your room is.
- **Not currently tracked over time.** Ice Cube keeps no history across
  launches, so the degradation use case — the most valuable one — is not yet
  available. It is the natural follow-up and needs persistence to land first.

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
