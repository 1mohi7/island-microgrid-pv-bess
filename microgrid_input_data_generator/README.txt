MICROGRID OPTIMIZER INPUT DATA GENERATOR
========================================

PURPOSE
-------
This package contains the source CSV data and MATLAB code for the three
hourly input files used by the microgrid optimizer:

  1. hourly_feeder_load_profile_spliting.csv
  2. loadshedding_schedule_1_year_with_status_flag.csv
  3. renewable_relevent_utc06_nasaPowerPoint_Hourly_20250101_20251231.csv

All three optimizer files contain 8760 hourly rows for calendar year 2025.

QUICK START
-----------
1. Extract this ZIP without changing the folder structure.
2. Open MATLAB and make this top-level folder the Current Folder.
3. Run:

       generate_all_optimizer_inputs

4. The final optimizer-ready files are saved in:

       generated_outputs/

The script prints the full file paths when it finishes.

FOLDER STRUCTURE
----------------
generate_all_optimizer_inputs.m
    One command to rebuild/audit all three data sources and verify the final
    optimizer-ready files.

verify_optimizer_inputs.m
    Checks row counts, timestamps, schemas, load balance, outage consistency,
    renewable missing values, and equality with the exact optimizer reference.

load_profile/
    load_config.m
    compute_warmth_weights.m
    compute_critical_load.m
    substation_load_profile.m
    scale_to_feeder.m
    plot_daily_demand.m
    hourly_temperature_feni__01_01_25_to_01_12_25_.csv

renewable/
    POWER_Point_Hourly_20241231_20251231_023d00N_091d40E_UTC.csv
    convertingutc00_to_utc06.m
    renewable_relevent_utc06_nasaPowerPoint_Hourly_20250101_20251231.csv

outage/
    loadshedding_schedule_1_year.m

reference_optimizer_inputs/
    Exact copies of the three CSVs currently used by the optimizer.


generated_outputs/
    Final optimizer-ready CSVs plus verification/audit reports.
    audit_rebuild/ is created when generate_all_optimizer_inputs is run and
    stores the raw model rebuilds for comparison.

LOAD MODEL
----------
The feeder is treated as a 1.50 MW connected/rated feeder. Demand is allowed
to exceed the connected rating by 0.25 MW, so the synthesized annual maximum
is 1.75 MW. This DOES NOT mean the annual average is 1.50 MW.

The exact optimizer reference has:
    mean total load       ~985.454 kW
    peak total load       1750.000 kW
    minimum total load    332.169 kW
    load factor           0.563116

Critical demand is facility-based, not a fixed percentage. The model contains:
    Clinic                       200 kW rated
    Water pumps                   40 kW rated
    Communications tower          15 kW rated
    Cyclone shelter cum school     8 kW rated

Because their schedules do not peak simultaneously, the exact optimizer
critical-load profile peaks at 259 kW. Critical + non-critical = total load
for every hour.

RENEWABLE MODEL
---------------
The raw NASA POWER resource is supplied in UTC and spans 31-Dec-2024 through
31-Dec-2025. convertingutc00_to_utc06.m shifts the clock labels by +6 hours,
then selects Bangladesh-local calendar year 2025. The result is exactly 8760
rows from 01-Jan-2025 00:00 through 31-Dec-2025 23:00.

The temperature CSV used by the load model has the same 8760 local timestamps,
and its T2M series matches the T2M column of the converted renewable file.

OUTAGE / LOAD-SHEDDING MODEL
----------------------------
loadshedding_schedule_1_year.m generates the design-year grid availability
trace using seed 42. The optimizer-format output columns are:

    hour, grid_available, outage_cause

where grid_available is 1 when supplied and 0 during an outage. outage_cause
is one of none, shedding, maintenance, or fault.

The exact optimizer reference contains:
    available       8002 h
    unavailable      758 h
    shedding         671 h
    maintenance       14 h
    fault             73 h

IMPORTANT REPRODUCIBILITY NOTE
------------------------------
The load model includes stochastic daily and hourly variation. The exact CSV
already used by the optimizer is therefore kept as an authoritative reference.
When generate_all_optimizer_inputs runs, it rebuilds each source into
`generated_outputs/audit_rebuild/` and compares it with the exact reference.
A rebuilt file is promoted to the final optimizer filename only when it matches.
Otherwise the exact optimizer reference is preserved, and GENERATION_AUDIT.txt
records the mismatch. This prevents a different random load realization from
silently replacing the data on which the optimizer results were based.

CODE FIXES APPLIED IN THIS PACKAGE
----------------------------------
1. scale_to_feeder.m:
   - fixed feederInfo metadata expected by plot_daily_demand.m;
   - writes optimizer-compatible datetime text;
   - exports load values to 3 decimals while preserving exact load balance.

2. convertingutc00_to_utc06.m:
   - robustly locates the NASA header;
   - performs the +6 h clock-label conversion explicitly;
   - validates 8760 continuous local hours and missing-value sentinels.

3. loadshedding_schedule_1_year.m:
   - default output filename changed to the optimizer-required
     loadshedding_schedule_1_year_with_status_flag.csv;
   - plotting disabled by default during data generation (numerical model
     and random seed are unchanged);
   - outage statistics now count final mutually exclusive cause tags, so a
     fault/maintenance overlap cannot be double-counted in summary totals.

4. generate_all_optimizer_inputs.m and verify_optimizer_inputs.m were added
   to make the complete process repeatable and auditable.

MATLAB REQUIREMENTS
-------------------
Designed for MATLAB R2025b / modern MATLAB. The original component models use
base MATLAB functionality; no Statistics Toolbox is required for the supplied
outage sampler or percentile helper.
