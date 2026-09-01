# Why is it hot? — what Ice Cube can tell you, and what it cannot

Ice Cube's Diagnose window answers four questions about this moment, and a
fifth about the months behind it. This file explains where each answer comes
from, why the numbers on screen deliberately do not add up, and the things the
app cannot see at all.

Every figure quoted here was measured on real hardware. Where something has not
been measured, it says so.

## The problem it solves

Ice Cube already showed temperature, fan speed, watts and °C/W. It had never
**said** anything — you were handed five numbers and left to do the reasoning.

The question people actually arrive with is *"what is making my machine hot
right now?"*, and its sharper form, the one [THERMAL.md](THERMAL.md) opens with:

> Is it hot because it is working hard, or because its cooling is failing?

This feature exists because of a case that happened while it was being built.
Two orphaned `yes` processes had been pinning 100 % CPU each for nearly three
hours. The fans were at 6800 RPM and the die at 71 °C. Ice Cube was fighting it
the entire time and had no screen that could name the cause — the diagnosis took
one API call the app was not making.

## The six questions

### 1. How hot is it?

The hottest CPU/GPU die sensor, against the **104 °C ceiling** the daemon
enforces (`SafetyMonitor.Limits.dieCeiling`). Bands are set by headroom:

| Band | Headroom | Die temperature |
| --- | --- | --- |
| Comfortable | ≥ 30 °C | ≤ 74 °C |
| Normal | 15–30 °C | 74–89 °C |
| Hot | 5–15 °C | 89–99 °C |
| Very hot | < 5 °C | > 99 °C |

**95 °C is deliberately "hot" and not an alarm.** Apple Silicon die sensors
legitimately reach 95–105 °C under sustained load. Warning at 95 °C would train
you to ignore the one band that matters.

A Mac reporting no die sensor gets no verdict here rather than one derived from
its battery.

### 2. Does the work explain it?

Watts in, degrees of rise out — the [cooling-efficiency](THERMAL.md) figure,
shown only once the machine has held steady for 20 seconds. Until then it says
it is measuring, never an estimate.

There is exactly one judgement in this row, and it is the one that needs no
history: **a hot die while the machine draws less than 15 W**. That threshold
comes from measurement — [SMC-KEYS.md](SMC-KEYS.md) recorded `PSTR` at 19.6 W
with background work running, and THERMAL.md measured 7.9 W at true idle — so
15 W sits above genuine idle and far below any real workload. A die in the hot
band with no load behind it points at blocked vents, a stopped fan, or dust.

It is keyed on **watts and not on °C/W** on purpose. `R` is not comparable
between machines (the ambient reference is a sensor inside the case), and this
claim has to hold on hardware nobody here has measured.

**This row still will not say "your cooling is degrading"** — that needs a
baseline rather than a moment, and it is question 5's job.

### 3. What is producing it?

Two independent sources, combined:

- **Which silicon leads** — CPU versus GPU, from the SMC's own sensor classes.
- **Which processes draw power** — from the kernel.

#### Where per-process watts come from

`proc_pid_rusage` fills a `rusage_info_v6`, whose **`ri_energy_nj`** field is the
cumulative energy a process has consumed since it started, in nanojoules. It is
a counter, not a rate, so a single reading says nothing about now. Two readings
a known interval apart do:

```
watts = (energy₂ − energy₁) × 1e-9 / seconds
```

This is public SDK surface (`sys/resource.h`), needs no entitlement and no root.

**These are real watts.** Activity Monitor's "Energy Impact" is a unitless,
undocumented composite; putting a number like that beside genuine watts from the
SMC would invite a comparison neither figure supports.

### 4. Is cooling doing all it can?

The row no other tool can produce, because only Ice Cube knows both the thermal
state *and* what it itself commanded:

- **At maximum** — your curve is already asking for 100 %. There is nothing left.
- **Headroom** — your curve is asking for less than it could at this
  temperature. A cooler preset would trade noise for degrees.
- **Stalled** — a fan is commanded above its floor but reads below it.

A fan *ramping up* legitimately reads far below its target for seconds
(`FanActivity` documents the measured ~1.5 s firmware dead time), so "stalled"
is scoped to reading below the fan's own minimum. Calling a ramp a failure would
fire on every preset change.

### 5. Is cooling getting worse?

The claim the "Not yet possible" section of this file named for three
versions. It is possible now, and the rest of this section is the small print
that makes it honest.

The verdict comes from persisted settled °C/W readings ([THERMAL.md's
"Tracking it over time"](THERMAL.md) has the mechanism and every constant):
the last 14 days against the earliest qualifying 14-day window at least a
month back, medians only, within one fan-speed band only, called only past
10 % (a one-day jump past 15 % against the band's own recent days). Six
states are possible — steady, worse, better, changed-abruptly, and two
refusals that name what is missing — plus "building a baseline" with the date
comparisons begin. Unlike the four rows above, this one is read from history
rather than measured, so it answers the instant the window opens and never
says "measuring". The full chart lives in the **Cooling History** window.

The row is deliberately not orange for a slow rise — a months-long drift has
no moment that deserves a warning, and colouring it would train the eye to
ignore the one state that means *now* (the abrupt change, which does get the
triangle). No trend state ever posts a notification.

### 6. Where is this heading?

Opt-in, off by default, in Settings → General → Experimental. The only row in
this window that is not a measurement.

Every other question here reports something read from the machine: the die is
79 °C, the fans are at 5,150 RPM, this process drew 4.2 W. This one reports a
**projection**, and says so in every state it can be in.

It answers three things when it can:

- **Where this load settles.** Not the current temperature — the one it is
  heading for, from the cooling this Mac has measured for itself at this fan
  speed.
- **Roughly when.** Stated as "about 2 min", never as a countdown. A model this
  approximate must not print `2:04`, and the formatting is where a reader looks
  to know how much precision to grant a number.
- **What the fans would buy.** If this Mac has run at a cooler fan speed and
  recorded it, the row says what that speed would settle at instead. This is
  the question the whole app exists for, answered *before* the noise is paid
  for rather than after.

If the projection crosses the 104 °C ceiling, it says when — and says that the
safety rule will force the fans to maximum first, because it will.

**The rule this row is governed by.** A projection must never be mistakable for
a reading. Three things enforce that: the title is a direction ("Where this is
heading") rather than a value; durations are approximate out loud; and every
refusal names what is missing, so a quiet row reads as *waiting* rather than as
a machine the app has decided is fine.

**What it needs before it can speak.** A time constant, which takes about
twenty measurements, each spanning three minutes of steady machine — roughly
ten minutes of ordinary use. And settled readings at the fan speed it is
currently in, which come from the same history the trend above uses. Until it
has both, it says which one is missing.

**What it is approximate about**, all named in the hover:

- Silicon responds in seconds and the chassis in minutes. This fits the slower
  of the two, so it is optimistic about the first few seconds of a load step.
- It treats the airflow reading as fixed while that is in fact climbing, worth
  a degree or two over a couple of minutes.
- It claims nothing beyond half an hour.
- **It never moves the fans.** It is a description of where the machine is
  already going, not an instruction to it.

Measured on a Mac14,9: τ = 73.7 s, from 89 estimates over 28 minutes of
ordinary use. See `docs/THERMAL.md` for the distribution and the method.

## Why the numbers do not add up — and must not

This is the most important section in the file.

The window shows two power figures from **two independent measurements of
different things**:

| Figure | Source | What it covers |
| --- | --- | --- |
| System total | SMC `PSTR` | The whole machine |
| Attributed | kernel `ri_energy_nj` | CPU energy of readable processes |

A real reading from the test machine (Mac14,9, macOS 26.4):

```
System:     41.6 W  (PSTR — the whole machine)
Attributed:  9.9 W  (CPU energy of all 408 readable processes)
Remainder:  31.7 W  (display, SSD, radios, GPU, and 205 processes needing root)
Processes:  408 readable of 613
```

The 31.7 W remainder is not an error. It is the display backlight, the GPU, the
SSD, the radios, charging losses, and every process Ice Cube cannot read. Ice
Cube **states the remainder** rather than hiding it, because a list that appeared
to sum to the total would be a lie — and it is precisely the lie a pie chart
would tell.

`attributedWatts` is summed across **every readable process**, not across the
twelve shown. Summing the visible list instead would fold several hundred small
processes into "unattributed" and overstate what the app cannot see. That was a
real bug during development, caught before it shipped, and it is the one number
this feature must not get wrong.

## What Ice Cube cannot see

- **GPU work per process.** `ri_energy_nj` is CPU energy. A game or a video
  export shows small process figures and a large remainder — the "GPU is
  leading" row is what covers that case, and the two must be read together.
- **Root-owned processes.** On the test machine, **205 of 613 PIDs were
  unreadable** without privilege. That set includes `kernel_task` and
  `WindowServer`, both of which can be genuinely large. The count is always
  shown.
- **The first moment.** Per-process power is a rate, so it needs two readings.
  The window says "measuring" for a second or two rather than apportioning a
  lifetime counter to an interval it did not cover.

## Privacy

Process names say what you work on. So:

- **Nothing leaves the machine.** Process names are **not** in the diagnostics
  JSON export — that file is designed to be attached to a public GitHub issue.
- **This window writes nothing.** The process list, the watts and the four
  verdicts about this moment are computed and discarded. One thing on it is
  read from disk rather than measured — question 5's cooling trend, which
  comes from the record described next.
- **The cooling history is a handful of numbers and a date.** Each settled
  reading stores when it was taken, the °C/W figure, the watts, die and
  airflow temperatures it was computed from, and the fan speed. It lives at
  `~/Library/Application Support/IceCube/cooling-history.json`, in the clear,
  and holds no process name, no file name, no serial number and no identifier
  of any kind — a salted hash ties it to this Mac without naming it. It never
  leaves the machine, it is **not** in the diagnostics export (a year of
  someone's thermal history is not something to hand over by accident), and
  **Clear History** in the Cooling History window deletes it outright.
- **Nothing is collected while the window is closed.** Sampling starts when the
  window opens and stops when it closes, which also discards what was collected.
  (Cooling readings record whenever the app runs — that is the point of a
  baseline — but they are the impersonal numbers above, not process data.)
- **A simulated run reads no real process.** `ICECUBE_SIMULATED=1` substitutes
  `MockProcessSampler`, whose fake PIDs start at 900001 — above Darwin's PID
  ceiling of 99999 — so a simulated PID cannot name a real process even by
  accident. Asserted in `SimulatedIsolationTests`.

`swift run icecube-diag --processes` prints the same data in the terminal. It is
opt-in and appears in neither the default summary nor `--json`, for the same
reason.

## Not yet possible

*"Your cooling is 18 % worse than in August"* lived here for three versions
and is now question 5. What remains out of reach:

- **Comparing your Mac with anyone else's.** `R`'s reference is a sensor
  inside the case and its denominator is whatever this machine powers; the
  trend is self-comparison, forever.
- **Predicting *why* a load will change.** Question 6 projects where the
  current load is heading; it has nothing to say about whether that load is
  about to stop, because nothing in the SMC knows what the user is about to do.
- **Naming the cause rather than ranking it — with exactly one exception.**
  Dust is the usual reason at a slow pace, dried paste the next, but the app
  cannot see inside the machine and its copy never claims to.

  The exception is **charging**, added 2026-08-26. The rule guards against
  *inferring* a cause from a sensor pattern; charging is not inferred, it is
  read from IOKit as a fact — `kIOPSIsChargingKey`, in the same dictionary
  `PowerSourceMonitor` already fetches to answer wall-versus-battery. It is the
  one cause the app does not have to guess at, which is why it is the one it
  may name. See `ChargingWarmth`.

  It earns the exception by covering a real dead end. Charging dissipates
  roughly 6–10 W into the cells and charging circuitry — spread across the
  bottom case rather than concentrated on the die — so the machine feels
  distinctly warm while every question this window asks answers "nothing is
  wrong", correctly. Measured on a Mac14,9 charging: die 56 °C, both cells
  under 35 °C, no process above 0.03 W, fans already at 5235 RPM. The owner's
  hand disagreed with all four numbers and all four were right.
- **Any of this on a Mac with no power key or no airflow sensor.** No watts
  or no reference means no quotient; the row says which is missing rather
  than collecting a baseline forever.
- **A baseline built faster than time passes.** Readings record only while
  the app runs and the machine holds steady, so a Mac used three hours a day
  builds its baseline three times slower than one left on — and the first
  verdict cannot arrive before day 44 on any machine, because the epochs need
  a month of distance to mean anything.
