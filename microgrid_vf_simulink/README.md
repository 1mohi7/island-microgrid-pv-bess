# Microgrid V/f Simulink scenario package

This package generates a **MATLAB/Simulink R2025b** low-fidelity, average-value dynamic model for the five presentation simulations discussed in the project:

1. Grid loss -> islanding, with non-critical load shed 100 ms later.
2. +20% critical-load step while islanded.
3. 50% PV availability drop while islanded.
4. Diesel trip while PV+BESS are already insufficient without diesel.
5. Grid restoration, resynchronization, and PCC reconnection.

## Important model boundary

This is deliberately **not an EMT/switching Simscape model**. The available project data define hourly energy dispatch and component sizes, but do not define inverter filter values, DC-link dynamics, detailed machine reactances, feeder/transformer impedances, protection curves, or manufacturer control gains. Pretending those are known would create false precision.

The model therefore uses an average-value V/f representation with BESS grid-forming droop, source power-response dynamics, source limits, a voltage/reactive-power response, load shedding, and PCC synchronization. It is appropriate for presentation-scale **frequency, RMS-voltage, and active-power sharing** plots. Use a detailed Simscape Electrical / EMT model later for fault current or critical-clearing-time studies.

## Bus assumption

The dynamic demonstration uses a **400 V line-line, 50 Hz equivalent three-phase bus** (about 230 V line-neutral). This is an equivalent LV microgrid bus, not a claim that the physical Feni feeder is 400 V. Your feeder study remains an 11 kV distribution-feeder problem.

## Project design used

The script reads `../matlab/results/optimizerResults.mat` directly and uses the outage-aware sizing:

- PV: 1266 kW
- BESS: 193 kWh
- BESS inverter: 259 kW
- Diesel: 150 kW
- BESS dispatch limit: 0.5C = 96.5 kW

It reads the project load power factor, battery limits, and other optimization parameters directly from `matlab/results/optimizerResults.mat`, so the dynamic run uses the exact parameter set associated with the optimized design. No duplicate MAT-file is needed in the Simulink folder.

## Dynamic assumptions that are not measured project data

They are grouped at the top of `run_microgrid_vf_scenarios.m` so they can be sensitivity-tested:

- BESS P-f droop: 2.5%
- BESS Q-V droop: 2.5%
- Effective aggregate frequency-response constant: 3.0 s
- BESS active-power time constant: 40 ms
- BESS reactive-power time constant: 30 ms
- PV power response: 50 ms; emergency island curtailment: 30 ms
- Secondary dispatch response: 0.60 s
- Diesel governor time constant: 0.20 s
- Diesel breaker-trip decay: 20 ms
- Initial phase mismatch in reconnection case: 15 deg

The 2.5% droop choice follows the simple droop settings used in MathWorks' islanded microgrid example. The other fast response constants are explicit demonstration assumptions and should be replaced if manufacturer/test data become available.

## Real operating hours selected from the 8760-hour project data

- Scenario 1: 23-Oct-2025 11:00 (high PV and still non-zero grid import after BESS reaches 0.5C)
- Scenario 2: 28-Feb-2025 07:00
- Scenario 3A: 26-Feb-2025 16:00
- Scenario 3B: 01-Jan-2025 16:00
- Scenario 4: 02-Jan-2025 09:00

The exact kW values are printed in the MATLAB Command Window when the runner starts.

## Run

Keep the project folder structure intact so these paths exist:

- `matlab/results/optimizerResults.mat`
- `microgrid_vf_simulink/run_microgrid_vf_scenarios.m`
- `microgrid_vf_simulink/build_microgrid_vf_model.m`
- `microgrid_vf_simulink/microgrid_vf_sfun.m`

The runner resolves these paths from its own location, so the MATLAB Current Folder can be anywhere. Then run:

```matlab
run_microgrid_vf_scenarios
```

The script creates `microgrid_vf_model.slx` automatically and writes PNG, FIG, CSV, and MAT outputs to:

```text
vf_results/
```

## Figure titles

Every figure title explicitly states the event and which components are ON/OFF, as requested.

### Power sign convention

- Grid: positive = import, negative = export.
- BESS: positive = discharge, negative = charge.
- PV and diesel: positive = generation.
