# Surge

## What surge is

Motors don't start gently. A fridge compressor, a water pump, an air
conditioner — each one pulls several times its normal running power for the
first second or two of starting, then settles down.

A fridge rated 540 W can pull about 1,600 W while its compressor kicks in.

That spike is the **surge**. It barely uses any energy (it's over in a second,
so it doesn't change your battery or panel sizing at all), but the inverter has
to be able to supply it. If it can't, the inverter trips or the motor just
buzzes and never starts — with a system that looks perfectly sized on paper.

So surge affects **one thing only: the inverter size.**

---

## The surge factor

Every appliance in the app carries a *surge factor* — how many times its
running watts it needs to start.

| Appliance type | Surge factor | Example |
|---|---|---|
| Lights, TV, laptop, kettle, iron | **1.0** (no surge) | resistive or electronic, nothing to spin up |
| Fan, freezer | 2.0 | small motors |
| Blender, washing machine, drill, A/C (variable-speed) | 2.5 – 3.0 | |
| Fridge / freezer | 3.0 | a 540 W fridge peaks near 1,620 W |
| Air conditioner (standard) | 4.0 | the worst common household load |
| Water pump | 6.0 | |

These come preset per appliance, so the user never has to know them. Anything
without a motor stays at 1.0 and contributes no surge at all.

---

## How the app uses it

Three rules, applied in order.

### 1. Only the biggest motor counts

Every motor in the house doesn't start in the same second. Designing for that
would mean buying an inverter two or three times larger than anyone needs.

So the app finds the **single appliance with the largest surge** and uses only
that one. The rest are counted at their normal running watts.

### 2. Surge sits on top of the running load

The spike doesn't happen in an empty house — the lights, TV and fridge are
already on when the pump starts. So:

```
Peak demand  =  everything running normally  +  the biggest motor's extra spike
```

"Extra spike" means the amount *above* what that motor was already drawing, since
its running watts are already in the first figure.

### 3. The inverter is sized two ways, and the bigger one wins

```
A.  Running load  ×  1.25          (normal continuous duty, with headroom)
B.  Peak demand   ÷  2             (inverters handle ~2× their rating for a few seconds)
```

Whichever is larger sets the minimum, then the app rounds **up** to the next
real inverter size you can actually buy (800, 1000, 1500, 2000, 2500, 3000,
3500, 5000 W and so on).

---

## Worked example

A house with lights, a TV, a fridge and a water pump:

| Appliance | Running watts | Surge factor | Extra spike |
|---|---|---|---|
| 6 × LED bulbs | 60 W | 1.0 | — |
| TV | 100 W | 1.0 | — |
| Fridge (20 cf) | 540 W | 3.0 | 1,080 W |
| Water pump | 500 W | 6.0 | **2,500 W** |
| **Running total** | **1,200 W** | | |

The pump has the biggest spike, so it's the one that counts:

```
Peak demand = 1,200 W running + 2,500 W pump spike = 3,700 W

A.  1,200 × 1.25  =  1,500 W
B.  3,700 ÷ 2     =  1,850 W   ← larger, so this wins

Next standard size up  →  2,000 W inverter
```

Without accounting for surge you'd have bought a 1,500 W inverter, and the pump
would trip it every time it started.

---

## What surge does *not* affect

- **Battery size** — the spike lasts seconds and uses almost no energy.
- **Panel / array size** — same reason.
- **Cable and breaker sizing** — these are sized for continuous current, not
  momentary spikes.

Surge only ever changes the inverter.

---

## Known gaps

Three things the current calculation doesn't handle. None of them break normal
household designs, but they're worth knowing:

1. **Loads marked "not simultaneous" are slightly understated.** If a motor is
   excluded from the running load, its running watts aren't in the total — so
   adding only its *extra* spike undercounts the real peak by its running watts.

2. **Quantity multiplies the surge.** Three fridges are treated as three
   compressors starting at once, which contradicts the "only the biggest motor
   starts" rule the sizing itself is built on. Surge is realistically a
   per-unit figure.

3. **The battery isn't checked against the surge.** A correctly sized inverter
   can still fail if the battery bank (or its BMS current limit) can't deliver
   that spike for the second or two it lasts. The app warns on high *continuous*
   discharge current, but nothing tests the peak.

---

## Where this lives in the code

| What | File |
|---|---|
| `surgeFactor`, `surgeW`, `surgeExtraW` on each appliance | [lib/models/appliance.dart](../lib/models/appliance.dart) |
| Surge factor per preset appliance | [lib/data/appliance_presets.dart](../lib/data/appliance_presets.dart) |
| Finding the biggest motor, peak demand | [lib/services/sizing_service.dart](../lib/services/sizing_service.dart) — Step 1 |
| Inverter sizing, the two-way comparison | [lib/services/sizing_service.dart](../lib/services/sizing_service.dart) — Step 6 |
| The 2× inverter surge assumption | `_inverterSurgeCapability` in the same file |
| Standard inverter sizes | [lib/data/standard_sizes.dart](../lib/data/standard_sizes.dart) |
