# How the engine works

Everything the app *calculates* lives in two services and the data tables they
read. This document covers all of it: how a list of appliances becomes a bill
of materials, and how a stream of sensor packets becomes a fault code.

There is a companion document, [surge.md](surge.md), that covers startup surge
in isolation. This one covers the rest.

---

## Contents

1. [The shape of the system](#1-the-shape-of-the-system)
2. [Part 1 — Sizing](#2-part-1--sizing)
   - [Inputs](#21-inputs)
   - [The eleven steps](#22-the-eleven-steps)
   - [Worked example](#23-worked-example-lagos-household)
   - [The derate model](#24-the-derate-model)
   - [Standard sizes and the round-up rule](#25-standard-sizes-and-the-round-up-rule)
   - [Warnings](#26-warnings)
   - [Cost](#27-cost)
3. [Part 2 — Fault diagnosis](#3-part-2--fault-diagnosis)
   - [Where the numbers come from](#31-where-the-numbers-come-from)
   - [Thresholds](#32-thresholds)
   - [The three gates](#33-the-three-gates)
   - [Fault codes](#34-fault-codes)
   - [Debounce](#35-debounce)
   - [Health score](#36-health-score)
   - [Degraded sensing](#37-degraded-sensing)
4. [The bridge between the two](#4-the-bridge-between-the-two)
5. [Persistence](#5-persistence)
6. [Known gaps](#6-known-gaps)
7. [Where everything lives](#7-where-everything-lives)

---

## 1. The shape of the system

Two engines, one shared description of the installation.

```
         APPLIANCE LIST                       ESP32 TOOL (BLE)
               |                                     |
               v                                     v
      ┌──────────────────┐                  ┌──────────────────┐
      │  SizingService   │                  │   BleService     │
      │  11 steps        │                  │   JSON packets   │
      └────────┬─────────┘                  └────────┬─────────┘
               │ SizingResult                        │ SensorData
               v                                     v
      ┌──────────────────┐   thresholds     ┌──────────────────┐
      │   SystemConfig   │─────────────────>│ FaultDiagnosis   │
      │  (saved_systems) │                  │    Service       │
      └──────────────────┘                  └────────┬─────────┘
                                                     │ DiagnosisReport
                                                     v
                                              health_readings
                                              fault_events
```

`SystemConfig` is the join. Before it existed, the sizer supported 12/24/48 V
and two battery chemistries while the fault engine was hardcoded to a 300 W
panel on a 12 V lead-acid bank — so on any other system every battery threshold
in the diagnosis was simply wrong. Now the diagnosis reads its thresholds from
whichever system the user has marked active.

---

## 2. Part 1 — Sizing

[lib/services/sizing_service.dart](../lib/services/sizing_service.dart)

Eleven sequential steps. Each consumes the previous step's output; nothing
iterates back. Every component output rounds **up** to a purchasable standard
size, which is what makes the result a bill of materials rather than a set of
raw numbers.

### 2.1 Inputs

[lib/models/sizing_input.dart](../lib/models/sizing_input.dart). Everything has
a documented default, so the engine runs from a bare appliance list.

| Input | Default | Notes |
|---|---|---|
| `appliances` | — | the only required field |
| `city` | `Lagos` | picks the PSH series |
| `pshMode` | `worstMonth` | worst month vs annual average |
| `systemVoltage` | null → recommended | 12 / 24 / 48 |
| `chemistry` | `lithium` | drives DoD and round-trip efficiency |
| `autonomyDays` | 2 | days with no sun |
| `panel` | 300 W Mono 60-cell | full datasheet spec |
| `batteryUnitAh` | 200 | capacity of one 12 V block |
| `controllerPreference` | `auto` | or force MPPT / PWM |
| `inverterEfficiency` | 0.90 | CED §8.4.1 gives 0.85–0.90 |
| `derate` | `DerateModel()` | the loss table, see §2.4 |
| `availableRoofM2` | null | null skips the fit check |
| cable run lengths | 12 / 3 / 2 / 15 m | PV→controller, →battery, →inverter, →board |
| `cableAmbientC` | 40 | ampacity derating |
| `futureLoadWh` | 0 | expansion headroom, treated as AC |
| `costs` | `UnitCosts.defaults()` | naira, editable |
| `essentialOnly` | false | re-run without optional loads |

Each appliance ([lib/models/appliance.dart](../lib/models/appliance.dart))
carries four fields beyond the obvious ones, each fixing a specific failure
mode:

- **`dutyCycle`** — a fridge is plugged in 24 h but its compressor runs a
  fraction of that. Without this the user types 24 hours and the whole system
  triples.
- **`loadType`** — DC loads bypass the inverter, so only AC loads get divided
  by inverter efficiency.
- **`surgeFactor`** — motors draw 3–7× rated for a second or two on start.
- **`simultaneous`** — summing every appliance as concurrent oversizes the
  inverter badly.

Derived per appliance:

```
dailyWh     = watts × quantity × hoursPerDay × dutyCycle
runningW    = watts × quantity
surgeW      = watts × quantity × surgeFactor
surgeExtraW = surgeW − runningW
```

The preset library
([lib/data/appliance_presets.dart](../lib/data/appliance_presets.dart)) is a
transcription of the CED R08-002 Annexure-1 tables, with deliberate departures
documented in that file's header — most importantly that refrigeration duty
cycles are back-derived from the stated kWh/day rather than the bracketed
hours (the source table contradicts itself; taking the hours at face value
overstates fridge energy about 4.5×), and that air-conditioner watts come from
BTU/h ÷ EER rather than the 746 W-per-HP shaft-power convention.

### 2.2 The eleven steps

#### Step 1 — Load analysis

AC and DC energy accumulate separately.

```
acLoadWh   = Σ dailyWh over AC appliances  (+ futureLoadWh)
dcLoadWh   = Σ dailyWh over DC appliances
totalLoadWh = acLoadWh + dcLoadWh

runningLoadW    = Σ runningW over appliances flagged simultaneous
largestSurgeExtra = max(surgeExtraW)          ← one appliance only
requiredSurgeW  = runningLoadW + largestSurgeExtra

busEnergyWh = acLoadWh / inverterEfficiency + dcLoadWh
```

`busEnergyWh` is the energy that must actually leave the battery bank. DC loads
enter it untouched — applying inverter efficiency to them would overstate the
requirement.

Only the largest single motor surge is added. Two motors starting in the same
second is not a design case worth paying for. See [surge.md](surge.md).

#### Step 2 — System voltage

CED R08-002 §8.4.1 parameter A2, on **total** daily load:

| Daily load | Bus |
|---|---|
| ≤ 1 kWh | 12 V |
| 1 – 4 kWh | 24 V |
| > 4 kWh | 48 V |

If the user forced a voltage, that one is used and a caution is raised when it
differs from the recommendation.

#### Step 3 — Sun hours and array derate

PSH comes from [lib/data/psh_table.dart](../lib/data/psh_table.dart): NASA POWER
long-term monthly climatology (`ALLSKY_SFC_SW_DWN`), global horizontal, for 15
Nigerian cities. kWh/m²/day is numerically the same as peak sun hours.

CED §2.5 requires designing for the month of lowest average daily radiation,
not the annual mean. In Lagos that is July at 3.8 against an annual 4.59 — a
system sized on the average browns out through the rainy season.

```
designPsh   = min(monthly)          (worstMonth mode)
            = mean(monthly)         (annualAverage mode)
arrayDerate = product of array-side loss factors   (§2.4)
PGF         = designPsh × arrayDerate
bosFactor   = pvCable × chargeController × distributionCable × roundTrip
```

`PGF` is the LEONICS "panel generation factor", computed here rather than
looked up — LEONICS publishes 3.43 for Thailand and there is no equivalent
published figure for Nigerian cities.

#### Step 4 — Array

```
requiredGenerationWh = busEnergyWh / bosFactor
requiredArrayWp      = requiredGenerationWh / PGF
panelCount           = ceil(requiredArrayWp / panel.watts)        (min 1)
```

Controller **type** is decided here, before string layout, because it
constrains the layout:

- explicit preference wins;
- otherwise MPPT if the provisional array is > 1 kW **or** the bus is ≥ 48 V;
- otherwise PWM.

Then strings (`_configureStrings`):

```
chargingVoltage = systemVoltage × 1.2      (absorption/boost)
minSeries       = ceil(chargingVoltage / panel.vmpp)
```

- **PWM** passes array voltage straight to the battery, so the string sits just
  above charging voltage and no higher — anything more is wasted.
  `series = minSeries`, `parallel = ceil(panelCount / minSeries)`.
- **MPPT** converts surplus voltage into current, so longer strings are better
  (less current, thinner cable, lower I²R). The upper bound is the controller's
  maximum PV input class, with the 20 % cold-Voc margin applied *inside* the
  bound — not afterwards, or the recommendation silently jumps a voltage class
  and the user buys a needlessly expensive controller. Among the permitted
  series counts the engine picks the one that wastes the fewest panels, breaking
  ties toward more panels in series.

The panel count is then rounded up to fill the strings, so no string is
half-populated.

```
installedWp   = panelCount × panel.watts
arrayIsc      = parallelStrings × panel.isc
stringVmpp    = panelsInSeries × panel.vmpp
stringVocCold = panelsInSeries × panel.voc × 1.12
```

The 1.12 is the cold-weather Voc correction from the Port Harcourt field guide.
String Voc is the figure that must stay below the controller's maximum PV input;
exceeding it destroys the controller immediately.

#### Step 5 — Battery

CED R08-002 §6.5, with inverter efficiency already applied per load type inside
`busEnergyWh`, so what remains here is the distribution-cable term:

```
requiredAh      = (busEnergyWh / distributionCable) × autonomyDays
                  ────────────────────────────────────────────────
                            systemVoltage × DoD

batteriesInSeries = round(systemVoltage / 12)            clamped 1–8
batteryStrings    = ceil(requiredAh / batteryUnitAh)     clamped 1–99
batteryCount      = batteriesInSeries × batteryStrings
installedAh       = batteryStrings × batteryUnitAh
usableStorageWh   = installedAh × systemVoltage × DoD
```

Depth of discharge is 0.50 for lead-acid, 0.80 for LiFePO4
([lib/models/enums.dart](../lib/models/enums.dart)).

#### Step 6 — Inverter

Two independent requirements; the larger wins.

```
A. runningLoadW × 1.25              continuous duty + headroom
B. requiredSurgeW / 2.0             units handle ~2× for a few seconds

inverterW = nextStandard(max(A, B))
```

Full treatment in [surge.md](surge.md).

#### Step 7 — Charge controller

MPPT converts surplus array **voltage** into charging current, so its rating
derives from array watts. PWM passes array **current** straight through, so its
rating derives from Isc.

```
MPPT:  rawA = (installedWp / systemVoltage) × 1.25
PWM:   rawA = arrayIsc × 1.3                        (LEONICS)

controllerCount = ceil(rawA / largest stocked rating)   clamped 1–8
controllerA     = nextStandard(rawA / controllerCount)
minVocRating    = nextStandard(controllerVocClasses, stringVocCold × 1.2)
```

A single controller may not be able to carry the array. Rounding up to the
largest standard size would silently under-rate the system, so the array is
split across parallel units instead.

#### Step 8 — Cable

Four runs, each sized by the larger of voltage drop and ampacity:

```
A(mm²) = (2 × ρ × I × L) / (V × dropFraction)          ρ = 0.0175 Ω·mm²/m
```

The factor of 2 covers out-and-back conductor length. Taking the larger of the
two results matters: on a short run the voltage-drop calculation alone returns
a conductor thin enough to overheat — which is why in practice most runs in a
domestic system come out **ampacity-governed**.

Total DC drop budget is 4 % (CED §7.6), allocated:

| Run | Budget | Current basis |
|---|---|---|
| PV array → controller | 2 % | `arrayIsc × 1.25` at `stringVmpp` |
| Controller → battery | 1 % | `controllerA × controllerCount` at bus V |
| Battery → inverter | 1 % | `inverterW / V / 0.9 × 1.25` at bus V |
| Inverter → board | 3 % (AC) | `inverterW / 220 × 1.25` at 220 V |

CED's whole-path 4 % budget is used rather than the field guide's per-run 3 %,
because a per-run allowance permits an out-of-spec cumulative drop.

Ampacity is derated for ambient temperature (IEC 60364-5-52 style):

| Ambient | Factor |
|---|---|
| ≤ 30 °C | 1.00 |
| ≤ 35 °C | 0.94 |
| ≤ 40 °C | 0.87 |
| ≤ 45 °C | 0.79 |
| ≤ 50 °C | 0.71 |
| > 50 °C | 0.61 |

#### Step 9 — Protection

Overcurrent devices are sized to protect the **conductor**, not the load.

| Device | Sizing |
|---|---|
| PV string fuse | `panel.isc × 1.56`, only when ≥ 3 parallel strings |
| Array breaker | `arrayIsc × 1.56`, DC class from `stringVocCold × 1.2` |
| Controller breaker | `controllerA × count × 1.25` |
| Battery breaker | `batteryToInverterA` |
| Battery isolator | `batteryToInverterA × 1.25` |
| AC breaker | `acOutputA` |
| RCD | 30 mA |
| DC SPD | class from `stringVocCold × 1.2`, 60 kA |
| AC SPD | 275 V, 40 kA |
| Earth | 16 mm², 2 rods |

The 1.56 PV factor is 1.25 for irradiance enhancement × 1.25 for safety. The
60 kA DC SPD reflects high lightning incidence in southern Nigeria.

All DC devices must be **DC-rated** — an AC breaker will arc and weld on DC.

Protection chain, as shown on the results screen:

```
PV array      → DC isolator → string fuses + DC SPD → DC breaker → controller
Battery bank  → battery fuse/breaker → battery isolator → inverter
Inverter      → AC SPD → AC MCB + RCD → distribution board
All frames, rails, chassis and SPDs → earth rod
```

#### Step 10 — Validation

See §2.6.

#### Step 11 — Cost

See §2.7.

### 2.3 Worked example: Lagos household

Six loads, Lagos, worst month, lithium, 2 days autonomy, 300 W 60-cell modules,
200 Ah battery units, all other inputs at their defaults.

| Appliance | Running W | Hours | Duty | Wh/day | Surge extra |
|---|---:|---:|---:|---:|---:|
| LED bulb × 6 | 57 | 6 | 1.00 | 342 | — |
| TV LED 43" | 65 | 5 | 1.00 | 325 | — |
| Ceiling fan 70 W × 2 | 140 | 10 | 1.00 | 1 400 | 140 |
| Refrigerator/Freezer 20cf | 540 | 24 | 0.139 | 1 801 | 1 080 |
| Laptop | 35 | 6 | 1.00 | 210 | — |
| Water pump | 375 | 2 | 1.00 | 750 | **1 875** |
| **Total** | **1 212 W** | | | **4 828 Wh** | |

**Step 1.** All AC, so `busEnergy = 4 828 / 0.90 = 5 365 Wh/day`. Peak demand
is `1 212 + 1 875 = 3 087 W` (pump is the biggest motor).

**Step 2.** 4.83 kWh/day → **48 V**.

**Step 3.** Lagos July = 3.80 PSH (annual 4.59).
Cell temperature by NOCT at 32 °C ambient = 63.2 °C, so the temperature factor
is `1 + (−0.45/100) × (63.2 − 25) = 0.828`.
Array derate = `0.828 × 0.95 × 0.97 × 0.95 × 0.99 × 0.97 = 0.696`.
**PGF = 3.80 × 0.696 = 2.65.**
BOS = `0.98 × 0.98 × 0.98 × 0.95 = 0.894`.
Whole-chain factor including inverter = **0.560** (CED publishes 0.60).

**Step 4.** `5 365 / 0.894 = 6 000 Wh` must be generated;
`6 000 / 2.65 = 2 269 Wp` required; `ceil(2 269/300) = 8` panels.
2 400 Wp > 1 kW and 48 V, so **MPPT**.
`minSeries = ceil(57.6/32.5) = 2`; cold Voc per panel with margin = 53.1 V, so
the 250 V class allows up to 4 in series. Both 2S and 4S fit 8 panels exactly;
the tie breaks toward more in series → **4S × 2P**.
Array: 2 400 Wp, Isc 19.6 A, string Vmpp 130 V, string Voc cold 177 V, 13.1 m².

On the annual average the array would have been 1 878 Wp — the worst-month
premium is **+20.8 %**, which the results screen shows side by side rather than
imposing silently.

**Step 5.** `(5 365 / 0.98) × 2 / (48 × 0.80) = 285 Ah`.
4 in series × 2 strings = **8 × 200 Ah**, 400 Ah installed, 15 360 Wh usable.

**Step 6.** `1 212 × 1.25 = 1 515 W`; `3 087 / 2 = 1 544 W` ← larger.
Next standard size: **2 000 W**.

**Step 7.** `2 400 / 48 × 1.25 = 62.5 A` → **one 80 A MPPT**, minimum PV input
rating 250 Vdc (177 V cold + 20 %).

**Step 8.**

| Run | Current | By drop | By ampacity | Selected | Actual drop |
|---|---:|---:|---:|---:|---:|
| PV → controller | 24.5 A | 3.96 mm² | 6.0 mm² | **6 mm²** | 1.32 % |
| Controller → battery | 80.0 A | 17.5 mm² | 35.0 mm² | **35 mm²** | 0.50 % |
| Battery → inverter | 57.9 A | 8.44 mm² | 16.0 mm² | **16 mm²** | 0.53 % |
| Inverter → board | 11.4 A | 0.90 mm² | 1.5 mm² | **1.5 mm²** | 1.81 % |

Total DC drop **2.35 %**, inside the 4 % budget. Every run is
ampacity-governed — this is the normal case, and the reason a drop-only
calculation is unsafe.

**Step 9.** No string fuses (only 2 parallel strings). Array breaker 32 A /
500 Vdc, controller breaker 100 A, battery breaker 63 A, isolator 80 A, AC
breaker 16 A.

**Step 11.** At the default unit costs: panels ₦912 000, batteries ₦3 040 000,
inverter ₦520 000, controller ₦416 000, cabling ₦255 576, protection ₦145 000,
mounting ₦176 000, labour ₦180 000 — **₦5 644 576**.

Estimated generation on a design-month day: 6 347 Wh. Installed capacity is
5.8 % above the calculated requirement, because the array rounds up to whole
panels and whole strings.

### 2.4 The derate model

[lib/data/derating.dart](../lib/data/derating.dart)

Structure and values follow the itemised table in CED R08-002 §2.4, which
multiplies out to a published total of 0.60. The losses split into two groups,
and the split is what prevents double-counting:

- **Array side** — everything between sunlight and DC power leaving the array.
  Multiplies PSH to give the PGF.
- **Conversion side** — everything between array output and load. Inflates the
  energy requirement.

| Factor | Default | Side | Source |
|---|---:|---|---|
| Cell temperature | computed (≈0.83) | array | NOCT + MATLAB coefficient |
| Soiling / dust | 0.95 | array | CED §2.3.1, §2.4 |
| Manufacturer tolerance | 0.97 | array | CED §2.4 |
| Shading | 0.95 | array | CED §2.4 |
| Orientation / tilt | 0.99 | array | CED §2.4 |
| Irradiance level | 0.97 | array | CED §2.4 |
| PV cable | 0.98 | conversion | CED §2.4 |
| Charge controller | 0.98 | conversion | CED §2.4 |
| Battery round trip | 0.90 / 0.95 | conversion | by chemistry |
| Distribution cable | 0.98 | conversion | CED §2.4 |
| Inverter | 0.90 | conversion | **AC loads only**, CED §8.4.1 |

Two deliberate departures from the published table:

1. **Temperature is computed, not the table's flat 0.90.** It uses the NOCT
   method for cell temperature and this project's own MATLAB-derived power
   coefficient. This is the one place where the loss model comes from the
   project's simulation work rather than being borrowed.

   ```
   T_cell = T_ambient + (NOCT − 20) × (G / 800)
   factor = 1 + (coeff%/100) × (T_cell − 25)
   ```

   At Lagos conditions a NOCT-45 module reaches ~63 °C, not the 25 °C of the
   STC rating.

2. **Dirt defaults to 0.95, not 0.97.** CED itself cites 0.93 for dusty sites
   in §2.3.1 and West African harmattan is at the harsh end of that range. 0.95
   is the midpoint, exposed as a parameter so it can be varied per site.
   `DerateModel.northernNigeria()` uses 0.93 and a 36 °C design ambient.

Note that the n-type TOPCon panel presets carry `-0.30 %/°C` rather than the
`-0.45` default. At 63 °C that is a derate of 0.885 rather than 0.828 — about
+6.9 % per module, so leaving the default in place would understate those
panels by roughly half a module in every ten.

### 2.5 Standard sizes and the round-up rule

[lib/data/standard_sizes.dart](../lib/data/standard_sizes.dart)

| Component | Stocked sizes |
|---|---|
| Inverter, W | 800, 1000, 1500, 2000, 2500, 3000, 3500, 5000, 6000, 8000, 10000, 12000, 15000 |
| Controller, A | 10, 20, 30, 40, 50, 60, 80, 100, 120, 150, 200 |
| Controller PV input, Vdc | 100, 150, 250, 500 |
| Breakers / fuses, A | 6 … 400 (17 steps) |
| DC voltage classes, Vdc | 500, 600, 800, 1000, 1500 |
| Battery units, Ah | 100, 150, 200, 220, 250 |
| Cable, mm² | 1.5 … 150 (13 steps) |

`nextStandard()` returns the **largest** stocked size when nothing satisfies the
requirement. That is the only sane value to return, but it is not a solution to
the problem asked — it reads as a valid answer and is not one. Every call that
can be driven by user load is therefore paired with an `exceeds…` predicate that
raises a critical warning:

- `exceedsStandard(standardInverterW, …)` → beyond single-phase inverter range
- `exceedsStandard(standardBreakerA, …)` → beyond standard OCPD
- `exceedsAmpacity(…)` → no single conductor can carry this run

Until the preset library gained 10 HP air conditioning and 10 kW heating
elements, no load could reach these. It can now.

Controller sizing solves the same problem differently, by splitting the array
across parallel units rather than clamping.

### 2.6 Warnings

Three levels — `info`, `caution`, `critical` — all non-blocking.

**Critical**

| Warning | Fires when |
|---|---|
| Beyond single-phase inverter range | required continuous W > 15 000 |
| No single conductor can carry *(run)* | run current exceeds 150 mm² at ambient |
| Beyond standard overcurrent protection | battery isolator > 400 A |
| Array will not fit | `installedWp / 110` > available roof m² |

The roof check budgets 110 W/m² of *usable* roof rather than raw module area,
to leave room for penetrations, walkways and firefighter access.

**Caution**

| Warning | Fires when |
|---|---|
| System voltage not optimal | user forced a voltage ≠ the recommendation |
| *n* parallel battery strings | more than 3 (CED §6.4.5 — circulating current) |
| PWM controller on a large array | PWM and > 1 kW installed |
| High battery discharge current | battery→inverter > 200 A |
| DC voltage drop above budget | total DC drop > 4 % |
| Autonomy below the usual minimum | < 2 days (CED §1.5.2 gives 2–6) |
| Sized on annual average sun hours | `pshMode == annualAverage` |

**Info** — controller PV input rating (always, with the cold-Voc figure),
parallel controllers, large lead-acid bank, motor load present, and a standing
reminder that protection devices are not optional.

### 2.7 Cost

Indicative naira figures in `UnitCosts`, editable. They move fast.

```
panels     = installedWp   × perPanelWatt
batteries  = batteryCount  × batteryUnitAh × perBatteryAh
inverter   = inverterW     × perInverterWatt
controller = controllerA   × perControllerAmp
cabling    = Σ (mm² × length × 2 × 1.15 × perCableMm2PerMetre)
protection = flat package
mounting   = panelCount × mountingPerPanel
labour     = flat
```

The 2 is two conductors per run; the 1.15 is terminations and slack.

---

## 3. Part 2 — Fault diagnosis

[lib/services/fault_diagnosis_service.dart](../lib/services/fault_diagnosis_service.dart)

A rule-based engine. One `SensorData` packet in, one `DiagnosisReport` out,
with streak state carried between calls.

### 3.1 Where the numbers come from

[lib/services/ble_service.dart](../lib/services/ble_service.dart)

Firmware contract, verified against hardware:

```
Device name  SolarDiag
Service      6e400001-…  (Nordic UART)
TX (notify)  6e400003-…  device → app, one JSON packet per second
RX (write)   6e400002-…  app → device, accepts the text "CAL"

{"v_panel":21.8,"v_batt":12.71,"current":2.18,
 "power":47.5,"t_panel":41.5,"t_amb":33.0,"ts":142}
```

Four things in the parsing path matter to the diagnosis:

- **MTU.** The packet is ~95 bytes; the default 23-byte ATT MTU truncates it
  and every frame fails to parse. The service requests 247.
- **Frame extraction.** Every complete `{…}` object in the buffer is extracted
  in order. An earlier version took `lastIndexOf('{')` and silently discarded a
  packet whenever two arrived in one read — and since the engine debounces over
  3 consecutive packets, dropped packets delay every fault.
- **Missing required keys are an error, not a zero.** If `v_panel`, `v_batt`,
  `current` or `power` is absent the packet is rejected and named in
  `errorMessage`. Defaulting them to 0.0 produced a connected device streaming
  a full packet of zeros with no error anywhere.
- **Absent temperature probes stay null.** The firmware sends JSON `null` for a
  probe that is not attached — never 0, never −99 — and that null propagates all
  the way to the engine. See §3.7.

Two independent staleness signals:

| Signal | Meaning |
|---|---|
| `isStale` | no packet for 3 s while nominally connected — the link is up but the feed is dead |
| `isFeedStalled` | packets arriving but the device's own `ts` has stopped advancing — the firmware's sensor loop is wedged |

`recalibrate()` writes `CAL` to re-zero the ACS712 current sensor. **The zero
calibration assumes no current is flowing** — calibrating under load bakes the
load current in as the new zero, and every subsequent current reading is wrong
by that offset. The scanner screen confirms before sending.

### 3.2 Thresholds

[lib/models/system_config.dart](../lib/models/system_config.dart) —
`DiagnosticThresholds.forConfig()`.

Battery thresholds are per-12 V-block figures scaled by the number of series
blocks. LiFePO4 sits on a much flatter curve than lead-acid and its useful
thresholds are entirely different numbers:

| Threshold | Lead-acid /block | LiFePO4 /block | 12 V LA | 24 V LA | 48 V LA | 12 V Li | 24 V Li | 48 V Li |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `batteryLow` | 12.2 | 12.8 | 12.2 | 24.4 | 48.8 | 12.8 | 25.6 | 51.2 |
| `batteryCritical` | 11.5 | 12.0 | 11.5 | 23.0 | 46.0 | 12.0 | 24.0 | 48.0 |
| `batteryOvercharge` | 14.8 | 14.6 | 14.8 | 29.6 | 59.2 | 14.6 | 29.2 | 58.4 |
| `absorptionThreshold` | 13.8 | 13.9 | 13.8 | 27.6 | 55.2 | 13.9 | 27.8 | 55.6 |

Array references come from the real module spec and string layout:

```
arrayVoc   = panel.voc  × panelsInSeries
arrayVmpp  = panel.vmpp × panelsInSeries
arrayIsc   = panel.isc  × parallelStrings
arrayRatedW = panelCount × panel.watts × degradationFactor
```

`degradationFactor = clamp(1 − 0.008 × ageYears, 0.70, 1.0)` — CED §2.4.1 gives
0.7–1 % per year, so the expected-output baseline decays with the installation
rather than being compared against its commissioning-day rating forever.

Thermal: `tempHigh = 70 °C`, `tempCritical = 85 °C` (from the project's ANSYS
work). Gate deltas: `daylightDeltaT = 3 °C`, `performanceDeltaT = 15 °C`.

### 3.3 The three gates

Most checks are conditional. The gates exist because each one corresponds to a
way the original implementation produced false or unreachable results.

**Gate 1 — daylight** (`panelTemp > ambientTemp + 3`)

Thermal only. The original gate was
`panelVoltage > 1.0 && panelTemp > ambientTemp + 5`, while PV-001 fires on
*voltage below 1 V in daylight*. A disconnected panel at noon reads 0 V, so the
gate closed and the fault could never raise — the condition being tested was
part of the test for whether to test it. A disconnected panel still heats in
the sun, so temperature alone is a valid daylight signal and does not make the
dead-panel fault unreachable.

**Gate 2 — controller regulating** (`batteryVoltage > absorptionThreshold`)

When the bank is full the controller deliberately throttles current: voltage
stays high, current collapses, power drops. That tripped CURR-001 and PERF-001
together — fifty health points off a healthy system, every sunny afternoon.
Current and performance checks are suppressed in absorption/float.

**Gate 3 — strong irradiance** (`panelTemp > ambientTemp + 15`)

Rated power is defined at 1000 W/m². At 08:00 or under cloud a healthy panel
produces a fraction of rating, which tripped PERF-001 CRITICAL on working
systems. The performance ratio is only evaluated when the panel-above-ambient
rise indicates strong irradiance.

What each gate controls:

| Domain | Needs daylight | Needs not-regulating | Needs strong irradiance | Needs panel probe |
|---|:--:|:--:|:--:|:--:|
| Panel (PV-001/002) | ✓ | | | ✓ |
| Current (CURR-001) | ✓ | ✓ | | ✓ |
| Performance (PERF-001/2/3) | ✓ | ✓ | ✓ | ✓ |
| Battery (BATT-001/2/3) | | | | |
| Temperature (TEMP-001/002) | | | | ✓ |

Temperature checks use absolute thresholds, so they need only the panel probe,
survive a missing ambient probe, and stay active at night — a module cooking
after dark is a genuine finding.

### 3.4 Fault codes

| Code | Domain | Severity | Condition | Cause |
|---|---|---|---|---|
| **PV-001** | panel | critical (−30) | daylight and `vPanel < 1.0 V` | disconnected panel, blown string fuse, open MC4, module failure |
| **PV-002** | panel | high (−20) | daylight and `vPanel < arrayVoc × 0.40` | shading, heavy soiling, degradation |
| **CURR-001** | current | high (−20) | `vPanel > arrayVmpp × 0.50` **and** `current < arrayIsc × 0.20` | loose/corroded connection, failed blocking diode, controller input fault |
| **PERF-001** | performance | critical (−30) | ratio < 0.30 | multiple module failure, major shading, string disconnection |
| **PERF-002** | performance | high (−20) | ratio < 0.50 | partial shading, heavy soiling, one failed module |
| **PERF-003** | performance | medium (−10) | ratio < 0.75 | soiling, mild shading, gradual degradation |
| **BATT-001** | battery | medium (−10) | `vBatt < batteryLow`, not under heavy load | consumption exceeding generation |
| **BATT-002** | battery | critical (−30) | `vBatt < batteryCritical`, not under heavy load | sustained deficit or a failed cell |
| **BATT-003** | battery | high (−20) | `vBatt > batteryOvercharge` | controller not regulating, or set for the wrong chemistry |
| **TEMP-001** | temperature | critical (−30) | `panelTemp > 85 °C` | cell hotspot, bypass diode failure, obstructed mounting |
| **TEMP-002** | temperature | medium (−10) | `panelTemp > 70 °C` | insufficient ventilation behind the modules |

The performance ratio:

```
expected = arrayRatedW × panel.temperatureDerate(panelTemp)
ratio    = power / expected
```

`arrayRatedW` is already age-decayed, and the temperature derate is the same
MATLAB-derived coefficient the sizer uses — so the comparison is against what
*this* array, at *this* age and *this* cell temperature, should be producing.

Bands within a domain are mutually exclusive and hoisted into their own
variables so each debounce streak accumulates independently. A shared
`else { clear() }` would zero a streak that is still building and make the more
severe code unreachable.

Battery checks are additionally gated on `current.abs() > arrayIsc × 0.6`
("under heavy load"), so voltage sag under a heavy inverter draw is not misread
as deep discharge, and on `batteryVoltage > 0.5 × seriesBlocks` as a
sanity check that something is connected at all.

### 3.5 Debounce

Every code must hold for **3 consecutive readings** (~3 s at one packet per
second) before it is raised. One noisy ADC sample should not declare a fault.

```dart
bool _trip(String code, bool condition) {
  if (!condition) { _streaks[code] = 0; return false; }
  final n = (_streaks[code] ?? 0) + 1;
  _streaks[code] = n;
  return n >= debounceCount;
}
```

Streaks are cleared when a gate closes — at night, all six daylight-only codes
are reset so nothing carries over into the next morning. `reset()` clears
everything, and the scanner screen calls it whenever a fresh connection begins.

### 3.6 Health score

**Worst fault per domain, not the sum of all faults.** A shaded panel raises
PV-002 and PERF-001 for one root cause; summing them double-counts.

```
for each domain:  worst[domain] = max(severity deduction among its faults)
health = clamp(100 − Σ worst[domain], 0, 100)
domainScores[domain] = clamp(100 − worst[domain], 0, 100)
```

Deductions: critical 30, high 20, medium 10, low 3. Five domains, so a
maximally broken system floors at 0 rather than going negative.

### 3.7 Degraded sensing

Daylight inference is a **differential** measurement, so one probe is not half
the signal — it is none of it. When either temperature is missing, the gate is
*undetermined* rather than false, and the panel, current and performance domains
are suppressed rather than guessed at.

This is tri-state on purpose:

| `daylightDetermined` | `isDaytime` | Meaning |
|---|---|---|
| true | true | array is in sunlight, all checks active |
| true | false | night or heavy cloud, daylight checks correctly inactive |
| false | false | **unknown** — checks suppressed, report is partial |

The old BLE layer coerced the firmware's `null` to 0.0, which turned the
daylight gate into `panelTemp > 3` — true for any panel in Lagos, day or night.
Daylight-only checks therefore ran around the clock against a fabricated ambient
reading.

`DiagnosisReport` surfaces this so the UI cannot render a suppressed diagnosis
as a passing one:

- `isPartialAssessment` — the score covers only part of the system
- `unavailableDomains` — panel, current, performance
- `panelTempAvailable` / `ambientTempAvailable`
- `summary` — reports degraded sensing **before** anything else, and never says
  "no faults detected". Silence about a domain that was not examined is absence
  of evidence, not evidence of absence.

The summary text is likewise explicit about the other two gates, so a healthy
system does not read as an untested one:

> No faults detected. The battery is full and the charge controller is limiting
> current, so current and performance checks are paused. This is correct
> behaviour, not a fault.

---

## 4. The bridge between the two

[lib/models/saved_system.dart](../lib/models/saved_system.dart)

A `SavedSystem` is a named `SystemConfig` with a source tag:

- **`sized`** — produced by the calculator, via
  `SystemConfig.fromSizingResult()`, so the monitoring side inherits the design
  assumptions automatically.
- **`existing`** — entered by hand for an already-installed system, so the
  engine can derive correct thresholds for it without a sizing run.

Exactly one row is flagged active. The scanner screen loads it on open and
builds its `FaultDiagnosisService` around that config's thresholds; with nothing
saved it falls back to `defaultSystemConfig()` — a 24 V lithium household setup,
8 × 300 W panels as 2S4P, 400 Ah, 1500 W inverter, 80 A MPPT.

This is what makes two features one platform rather than two calculators in one
binary.

---

## 5. Persistence

[lib/services/database_service.dart](../lib/services/database_service.dart) —
sqflite, schema version 2.

| Table | Contents |
|---|---|
| `health_readings` | every diagnosis: timestamp, health score, all six sensor values, fault count |
| `fault_events` | one row per fault *transition*, with `cleared_at` filled in when it stops |
| `saved_systems` | named `SystemConfig` JSON, source tag, active flag |

Fault events are edge-triggered, not level-triggered: the scanner screen diffs
the current fault codes against the previous set and inserts only codes that are
newly present, then calls `clearFaults()` with the still-active list to stamp
`cleared_at` on everything else. Without that diff, a fault held for an hour
would write 3 600 rows.

---

## 6. Known gaps

Things that are genuinely missing or wrong in what exists today. None of them
break a normal household design, but they should be known before the numbers
are defended.

### Sizing

1. **Cost ignores parallel controllers.** `_estimateCost` uses `controllerA`
   but not `controllerCount`, so a design split across three 200 A units is
   priced as one. Only affects arrays large enough to need splitting.
2. **Loads marked "not simultaneous" understate peak demand.** If a motor is
   excluded from the running load, its running watts are not in the total — so
   adding only its *extra* spike undercounts the real peak by its running watts.
3. **Quantity multiplies surge.** Three fridges are treated as three
   compressors starting at once, which contradicts the "only the biggest motor
   starts" rule the sizing is built on. Surge is realistically per-unit.
4. **The battery is not checked against surge.** A correctly sized inverter can
   still fail if the bank (or its BMS current limit) cannot deliver that spike.
   The app warns on high *continuous* discharge current; nothing tests the peak.
5. **Panel preset datasheet values are class-representative, not transcribed.**
   The file says so explicitly, twice. Verify against the datasheet of whichever
   module is actually cited before the numbers are published anywhere.
6. **PSH is global horizontal.** Designing on GHI is slightly conservative at
   Nigerian latitudes; the residual tilt deviation is carried by the orientation
   derate factor. Swapping in a plane-of-array series without removing that
   factor would double-count the tilt gain.

### Diagnosis

7. **`health_readings` declares `panel_temp` and `ambient_temp` as
   `REAL NOT NULL`, but `insertReading` passes the nullable values straight
   through.** A reading taken with a probe detached will fail the insert. The
   nullable-temperature work went through the engine and the BLE layer but not
   the schema.
8. **The scanner diagnoses `latestData` from the ChangeNotifier, not the
   `readings` stream.** `_processIncomingData` records every frame but calls
   `notifyListeners()` once per chunk, so when two packets arrive in one BLE
   read only the second reaches `diagnose()`. The BLE service's own comment says
   to feed the engine from `readings`. Effect is a slower debounce, not a wrong
   verdict.
9. **"Under heavy load" is scaled by `arrayIsc`.** The sensor measures one
   current; using array short-circuit current as the yardstick for *load*
   current is a proxy, and on a system whose loads are large relative to its
   array it will read as heavy load more often than it should.
10. **No cross-check between diagnosis and the design.** The engine knows what
    the array should produce but never reports the gap against the sizing run's
    `estimatedDailyGenerationWh` — energy over a day, as opposed to power at an
    instant, is not evaluated anywhere.

---

## 7. Where everything lives

| What | File |
|---|---|
| Eleven-step sizing engine | [lib/services/sizing_service.dart](../lib/services/sizing_service.dart) |
| Rule-based fault engine, `SensorData`, `FaultCode` | [lib/services/fault_diagnosis_service.dart](../lib/services/fault_diagnosis_service.dart) |
| BLE transport, packet parsing, staleness, calibration | [lib/services/ble_service.dart](../lib/services/ble_service.dart) |
| SQLite persistence | [lib/services/database_service.dart](../lib/services/database_service.dart) |
| Loss model, derate breakdown | [lib/data/derating.dart](../lib/data/derating.dart) |
| Monthly PSH by city, worst-month selection | [lib/data/psh_table.dart](../lib/data/psh_table.dart) |
| Stocked sizes, ampacity, round-up helpers, unit costs | [lib/data/standard_sizes.dart](../lib/data/standard_sizes.dart) |
| Appliance library and presets | [lib/data/appliance_presets.dart](../lib/data/appliance_presets.dart) |
| Appliance, preset, stepped families | [lib/models/appliance.dart](../lib/models/appliance.dart) |
| Module datasheet spec, NOCT, temperature derate | [lib/models/panel_spec.dart](../lib/models/panel_spec.dart) |
| Sizing inputs | [lib/models/sizing_input.dart](../lib/models/sizing_input.dart) |
| Sizing outputs, cable runs, protection, warnings, cost | [lib/models/sizing_result.dart](../lib/models/sizing_result.dart) |
| Shared system description and diagnostic thresholds | [lib/models/system_config.dart](../lib/models/system_config.dart) |
| Saved systems, default config | [lib/models/saved_system.dart](../lib/models/saved_system.dart) |
| Chemistry, controller type, PSH mode, load type | [lib/models/enums.dart](../lib/models/enums.dart) |
| Sizing UI, results screen | [lib/screens/sizing_screen.dart](../lib/screens/sizing_screen.dart) |
| Live monitoring UI, diagnosis wiring | [lib/screens/scanner_screen.dart](../lib/screens/scanner_screen.dart) |
| Manual entry of an existing system | [lib/screens/add_system_screen.dart](../lib/screens/add_system_screen.dart) |

### Tests

| File | Covers |
|---|---|
| [test/fault_diagnosis_null_temp_test.dart](../test/fault_diagnosis_null_temp_test.dart) | the tri-state daylight gate — suppression with a missing probe, TEMP and BATT surviving it, partial-assessment reporting, and a clean 100 % on full sensing |
| [test/appliance_steps_test.dart](../test/appliance_steps_test.dart) | preset library integrity, stepped families, the BTU/EER air-conditioner derivation, the over-range warning guards, and the n-type panel specs |
| [test/widget_test.dart](../test/widget_test.dart) | app smoke test |

### Sources the engine follows

- **LEONICS five-step method** — duty-cycled load entry, panel generation
  factor, Isc-based PWM controller sizing, 3× minimum for motor loads.
- **CED R08-002** (A. Bhatia, 8 PDH) — itemised derating table §2.4,
  worst-month design basis §2.5, battery equation §6.5, per-appliance AC/DC
  adjustment and system-voltage rule §8.4.1, 3-string parallel limit §6.4.5,
  4 % total voltage drop budget §7.6, appliance tables in Annexure-1.
- **Port Harcourt field guide** — dual controller formulas, controller Voc
  margin, motor surge multiples, complete protection chain.
- **This project's MATLAB single-diode simulation** — the −0.45 %/°C power
  coefficient in the computed temperature derate.
- **NASA POWER** — `ALLSKY_SFC_SW_DWN` monthly climatology for the PSH table.
- **This project's ANSYS work** — the 70 °C / 85 °C thermal thresholds.

Three places the implementation deliberately diverges from its sources, all
worth stating explicitly:

1. LEONICS applies a flat 1.3 uplift for all conversion losses. This engine
   decomposes it into the measurable parts, so the loss model responds to
   battery chemistry and AC/DC load mix instead of assuming one number for
   every system.
2. LEONICS uses a tabulated PGF (3.43, Thailand). No equivalent is published
   for Nigerian cities, so the PGF here is computed as worst-month PSH × array
   derate, with the temperature term from this project's own simulation.
3. Voltage drop follows CED's whole-path 4 % budget rather than the field
   guide's per-run 3 %, because a per-run allowance permits an out-of-spec
   cumulative drop.
