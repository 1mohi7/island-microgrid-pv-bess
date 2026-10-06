FENI SUBSTATION LOAD PROFILE MODEL
==================================

FILES
  load_config.m              All parameters. This is the only file to edit.
  compute_warmth_weights.m   Reads temperature CSV, computes daily warmth weights.
  compute_critical_load.m    Builds the critical-load subset in kW from
                             config.critical facility list and schedules.
  substation_load_profile.m  Main model. Run this.
  plot_daily_demand.m        Per-month and full-year daily-average figures.
  scale_to_feeder.m          Utility to scale the substation load to a feeder.

QUICK START
  1. Put all four .m files and your temperature CSV in one folder.
  2. In MATLAB, cd into that folder.
  3. Run:

        [hourlyLoad, monthlyStatsTable, modelInfo] = substation_load_profile();

     This loads the config, builds the profile, prints statistics, writes
     CSVs, and draws every figure including the per-month daily plots.

  Note: substation_load_profile.m works with the editor Run button because it
  defaults to load_config(). plot_daily_demand.m does NOT - it needs the load
  vector and modelInfo as inputs, so call it from the Command Window or let
  substation_load_profile call it for you.

CHANGING THE TEMPERATURE FILE
  Edit one line in load_config.m:
        config.temperature.fileName = 'your_file.csv';
  The calendar (year, day count, leap year, day-of-week) is derived from the
  dates inside the file, so nothing else needs changing.

  For non-NASA files, set config.temperature.fileFormat = 'generic' and fill
  in headerLineCount plus the column indices.

CHANGING SITE PARAMETERS
  All in load_config.m:
    config.site.*         name, coordinates, capacity, units (MW or kW)
    config.archetype.*    the hot and cold 24-hour archetype curves
    config.dayType.*      weekend day modifiers (rename fields per country)
    config.overlay(*)     additive block loads such as irrigation
    config.warmth.*       CDD base temperature, thermal inertia, normalisation
    config.stochastic.*   noise magnitudes, AR coefficient, random seed
    config.output.*       CSV and figure options

  Every parameter is tagged [MEASURED], [REPORTED] or [ASSUMED]. The
  [ASSUMED] ones are the list to vary in a sensitivity analysis.

OUTPUT FILES
  Substation level (substation_load_profile.m):
    load_profile_hourly.csv    8760 rows: hour, datetime, load
    load_profile_monthly.csv   monthly mean, peak, min, energy, load factor
    daily_mean_demand.csv      one row per day

  Feeder level (scale_to_feeder.m):
    hourly_feeder_load_profile_spliting.csv
                               8760 rows with columns:
                                 datetime               yyyy-mm-dd HH:MM
                                 hour                   1..8760
                                 non_critical_load_kW
                                 critical_load_kW
                                 total_load_kW
    feeder_load_profile_monthly.csv   monthly feeder statistics

CRITICAL LOADS
  The designated critical facilities are all connected to a single
  distribution FEEDER, so the critical / non-critical split is performed in
  scale_to_feeder.m against the feeder profile - NOT at substation level.
  Splitting the substation total would spread a feeder-local block of load
  across the whole 10 MW site and understate the critical share by roughly
  a factor of five.

  Edit config.critical in load_config.m to change the facility list or the
  schedules. Each facility is defined as a peak in kW plus a 24-hour shape
  vector (fractions of peak, index 1 = 00:00), with optional per-day
  overrides keyed by three-letter day name. Critical is a SUBSET of the
  feeder total: non_critical = total - critical.

  Because critical demand is nearly flat while total feeder demand swings
  by a factor of about five across the day, the critical SHARE is highest
  in the overnight trough and lowest at the evening peak. That variation is
  the quantity that matters for backup and storage sizing, and it is why
  the earlier flat criticalLoadFraction parameter has been removed.

  Typical run:

        [hourlyLoad, monthlyStats, modelInfo] = substation_load_profile();
        [feederLoad, feederMonthly, feederInfo] = ...
            scale_to_feeder(hourlyLoad, modelInfo);

TOOLBOX REQUIREMENTS
  Base MATLAB only. No Statistics Toolbox needed.
  exportgraphics requires R2020a; older releases fall back to print.
