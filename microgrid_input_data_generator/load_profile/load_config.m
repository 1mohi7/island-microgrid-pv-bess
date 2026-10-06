function config = load_config()
%LOAD_CONFIG  All parameters for the substation load model in one place.
%
%   config = load_config();
%   [hourlyLoad, monthlyStatsTable, modelInfo] = substation_load_profile(config);
%
%   Every quantity the model uses is defined here. No numbers are hardcoded
%   in the other files. To model a different site, copy this file, edit it,
%   and pass the result in.
%
%   Provenance tags used below:
%     [MEASURED] taken from data
%     [REPORTED] stated by substation operating staff
%     [ASSUMED]  judgement call - belongs in the sensitivity analysis

% =========================================================================
% SITE
% =========================================================================
config.site.name          = 'Feni rural distribution substation';
config.site.latitude      = 22.9733;
config.site.longitude     = 91.3850;
config.site.capacity      = 10.0;     % [REPORTED] rating, in site.units
config.site.units         = 'MW';     % 'MW' or 'kW'. The archetype curves
                                      % below must use the same units.

% =========================================================================
% TEMPERATURE INPUT
% =========================================================================
config.temperature.fileName = 'hourly_temperature_feni__01_01_25_to_01_12_25_.csv';

% 'nasa_hourly' : NASA POWER hourly point CSV, header row auto-detected
% 'nasa_daily'  : NASA POWER daily point CSV, header row auto-detected
% 'generic'     : any CSV - set headerLineCount and the column indices below
config.temperature.fileFormat      = 'nasa_hourly';

config.temperature.headerLineCount = [];   % 'generic' only: rows to skip
config.temperature.columnYear      = 1;    % 'generic' only
config.temperature.columnMonth     = 2;    % 'generic' only
config.temperature.columnDay       = 3;    % 'generic' only
config.temperature.columnHour      = 4;    % 'generic' only; [] if daily data
config.temperature.columnTemp      = 5;    % 'generic' only
config.temperature.missingValue    = -999; % sentinel for missing records

% =========================================================================
% WARMTH WEIGHT  (temperature to load coupling)
% =========================================================================
% One weight per DAY, in [0, maximumWarmthWeight]. Each day's load curve is
% a blend of the hot and cold archetypes using that day's own weight, so
% warm days in a cool month and cool days in a warm month are represented
% explicitly rather than being absorbed into random noise.

config.warmth.baseTemperatureC = 24;   % [ASSUMED] cooling degree-day base

% Thermal inertia. Cooling load does not track temperature instantaneously:
% building thermal mass and behavioural adaptation give a lag of a few days.
% Applied as an exponentially weighted moving average of daily CDD:
%     smoothed(d) = alpha*CDD(d) + (1-alpha)*smoothed(d-1)
% alpha = 1 removes the lag entirely; 0.4 gives roughly a 2-3 day memory.
config.warmth.thermalInertiaAlpha = 0.40;   % [ASSUMED]

% Reference for normalisation - what counts as weight 1.
%   'hottest_month' : the hottest month averages weight 1. Correct when the
%                     hot archetype was anchored to typical hot-season days,
%                     which is the case here.
%   'percentile'    : a chosen percentile of daily CDD maps to weight 1.
%   'max'           : the single hottest day maps to weight 1. Not advised -
%                     one freak day then sets the scale for the whole year.
config.warmth.referenceMode       = 'hottest_month';
config.warmth.referencePercentile = 98;    % 'percentile' mode only

% Individual days may exceed the reference. Allowing weights slightly above
% 1 extrapolates past the hot archetype, which is physically correct: an
% unusually hot day draws more than a typical hot day. Set to 1.0 to forbid.
config.warmth.maximumWarmthWeight = 1.25;  % [ASSUMED]

% =========================================================================
% ARCHETYPE DAILY CURVES   [site.units], index 1 = hour 00:00
% =========================================================================
% Leave archetypeFileName empty to use the vectors below. To calibrate
% against measured feeder data, point it at a CSV with 24 rows and columns
% [hour, hot, cold]; the inline vectors are then overridden.
config.archetype.archetypeFileName = '';

% HOT archetype [REPORTED]. Dawn minimum 04:00-05:00; domestic morning
% plateau 06:00-10:00 (housework and breakfast, before commercial opening);
% rise after 10:00 as shops and the bazar open; relaxation after 14:00 as
% trading slows and people return home to eat; evening peak 18:00-23:00
% about 2 units above the morning plateau; gradual overnight decay.
config.archetype.hotCurve = [4.30 3.90 3.60 3.40 3.20 3.30 4.00 4.40 ...
                             4.60 4.70 4.80 5.10 5.30 5.40 5.40 5.15 ...
                             5.00 5.20 6.00 6.50 6.50 6.30 5.90 5.00]';

% COLD archetype [REPORTED]. Morning plateau 2.6-3.4; evening peak retained
% at about 1.9 above the plateau because it is lighting-driven; markedly
% faster post-peak decay than the hot archetype.
config.archetype.coldCurve = [2.60 2.40 2.25 2.10 2.00 2.10 2.60 3.00 ...
                              3.20 3.30 3.40 3.50 3.55 3.60 3.55 3.45 ...
                              3.50 4.20 4.80 5.00 4.85 4.40 3.60 3.00]';

% =========================================================================
% DAY-TYPE MODIFIERS
% =========================================================================
% Multiplicative 24-element vectors keyed by three-letter day name. Days not
% listed are treated as normal working days. Bangladesh observes a
% Friday-Saturday weekend, but the two days are not equivalent.
%
% For a different country, rename these fields to that country's weekend
% days - the mechanism itself is not Bangladesh-specific.

% FRIDAY [REPORTED]. Almost nothing opens before Jumu'ah prayer, so
% commercial load is largely absent through the morning and early afternoon;
% trading resumes afterwards and the evening runs slightly busier than a
% working day. The morning reduction is modest because the morning plateau
% is predominantly domestic and unaffected by the day of week.
fridayModifier = ones(24,1);
fridayModifier(7:14)  = 0.90;    % 06:00 - 13:00, pre-Jumu'ah
fridayModifier(15:18) = 1.02;    % 14:00 - 17:00, trading resumes
fridayModifier(19:23) = 1.03;    % 18:00 - 22:00
config.dayType.Fri = fridayModifier;

% SATURDAY [ASSUMED]. Nominally weekend, but bazars and most shops trade
% close to normally. VERIFY LOCALLY - if Saturday is a full working day at
% this site, delete this field entirely.
saturdayModifier = ones(24,1);
saturdayModifier(10:18) = 0.99;  % 09:00 - 17:00
config.dayType.Sat = saturdayModifier;

% =========================================================================
% ADDITIVE OVERLAYS
% =========================================================================
% Block loads that switch on largely independently of the underlying
% domestic and commercial demand, so they are ADDED rather than multiplied.
% This is a struct array - add further elements for additional overlays.

% Boro irrigation pumping [MEASURED magnitude, REPORTED window].
% Continuous 23:00-10:00. Shaped rather than a step at the boundaries
% because pumps do not all start or stop together.
irrigationShape        = zeros(24,1);
irrigationShape(1:10)  = 1.00;   % 00:00 - 09:00, full
irrigationShape(11)    = 0.40;   % 10:00 shutdown taper
irrigationShape(24)    = 0.50;   % 23:00 ramp-in

config.overlay(1).overlayName    = 'Boro irrigation';
config.overlay(1).hourlyShape    = irrigationShape;
config.overlay(1).activeMonths   = [1 2 3 4];
config.overlay(1).monthlyMagnitude = [1.7 1.9 2.0 1.6];  % matches activeMonths

% =========================================================================
% CRITICAL LOADS  (subset of total demand, split out for resilience work)
% =========================================================================
% Facilities designated CRITICAL for survivability during outages. Every
% value here is in kW regardless of config.site.units. Each facility has:
%   name          : short label used in reports
%   peakKW        : rated peak draw in kW  [REPORTED]
%   weekdayShape  : 24-element vector of fractions of peak, index 1 = 00:00
%   dayOverrides  : optional struct with per-day-of-week shape overrides,
%                   keyed by three-letter day name (Sun,Mon,...,Sat)
%
% The critical load is computed as an independent time series in kW and
% then SUBTRACTED from the (unit-converted) substation total to give the
% non-critical residual. Total substation load is unchanged. If the modelled
% total ever falls below the critical draw at some hour, critical is capped
% to total and a warning is issued.

% CLINIC  [REPORTED 200 kW rated - large clinic / small hospital scale].
% 24/7 operation. Overnight baseline ~60% covers refrigeration, essential
% lighting, inpatient equipment; daytime rises to full peak during clinic
% hours. Modest Friday morning reduction reflects local weekday practice.
clinicWeekdayShape = [0.60 0.60 0.60 0.60 0.60 0.65 0.75 0.85 ...
                      1.00 1.00 1.00 1.00 0.95 0.95 1.00 1.00 ...
                      1.00 0.95 0.90 0.85 0.80 0.75 0.70 0.65]';
clinicFridayShape          = clinicWeekdayShape;
clinicFridayShape(7:14)    = clinicWeekdayShape(7:14) * 0.85;

config.critical(1).name         = 'Clinic';
config.critical(1).peakKW       = 200;   % [REPORTED]
config.critical(1).weekdayShape = clinicWeekdayShape;
config.critical(1).dayOverrides = struct('Fri', clinicFridayShape);

% WATER PUMPS  [REPORTED 2 x 20 kW = 40 kW rated].
% Village water supply pumping in two windows: morning fill 05:00-08:00 and
% evening fill 16:00-19:00, both pumps running at full load, with a taper
% hour at each end while the second pump ramps down.
pumpsShape        = zeros(24,1);
pumpsShape(6:8)   = 1.00;   % 05:00 - 07:00, both pumps at 40 kW
pumpsShape(9)     = 0.50;   % 08:00 taper
pumpsShape(17:19) = 1.00;   % 16:00 - 18:00, both pumps at 40 kW
pumpsShape(20)    = 0.50;   % 19:00 taper

config.critical(2).name         = 'Water pumps';
config.critical(2).peakKW       = 40;    % [REPORTED]
config.critical(2).weekdayShape = pumpsShape;
config.critical(2).dayOverrides = struct();

% COMMS TOWER  [REPORTED 15 kW]. Flat 24/7 - radio, rectifiers, cooling,
% battery bank float charge. No day-of-week or seasonal variation.
config.critical(3).name         = 'Comms tower';
config.critical(3).peakKW       = 15;    % [REPORTED]
config.critical(3).weekdayShape = ones(24,1);
config.critical(3).dayOverrides = struct();

% CYCLONE-SHELTER-CUM-SCHOOL  [REPORTED 8 kW school-mode rated].
% Single dual-function building common in coastal Bangladesh. Modelled in
% its normal school role: weekday school hours 07:00-15:00 at rated load,
% small standby baseline (1.5 kW - safety lights, comms) at all other
% hours and on Fri/Sat. Cyclone-activation events (which lift the draw
% toward 10 kW for fans, pumps, extra lighting) are rare and not
% deterministically scheduled here; treat as a separate event overlay if
% required for a specific study.
shelterStandbyFraction    = 1.5 / 8;                   % 1.5 kW standby
shelterWeekdayShape       = ones(24,1) * shelterStandbyFraction;
shelterWeekdayShape(8:16) = 1.00;                       % 07:00-15:00
shelterWeekdayShape(17)   = 0.50;                       % 16:00 taper
shelterWeekendShape       = ones(24,1) * shelterStandbyFraction;

config.critical(4).name         = 'Cyclone shelter cum school';
config.critical(4).peakKW       = 8;     % [REPORTED - school mode]
config.critical(4).weekdayShape = shelterWeekdayShape;
config.critical(4).dayOverrides = struct('Fri', shelterWeekendShape, ...
                                          'Sat', shelterWeekendShape);

% =========================================================================
% STOCHASTIC COMPONENT
% =========================================================================
% Day-to-day scaling. With daily temperature coupling active, the
% weather-driven part of day-to-day variation is already explicit in the
% warmth weights, so this term represents only NON-WEATHER variation
% (activity, holidays, local events). It is therefore smaller than it would
% be under monthly coupling - do not raise it back to a monthly-model value
% or the weather effect will be counted twice.
% [ASSUMED - calibrate from measured daily energy totals when available]
config.stochastic.dailyStdDev  = 0.035;

% Hour-to-hour residual, AR(1). The autoregressive structure avoids the
% physically implausible hour-to-hour discontinuities of independent draws.
config.stochastic.hourlyStdDev = 0.030;   % [ASSUMED]
config.stochastic.arCoefficient = 0.60;   % [ASSUMED]

config.stochastic.randomSeed   = 42;      % fixed - report this in the paper
config.stochastic.floorFraction = 0.05;   % floor as a fraction of mean load

% =========================================================================
% OUTPUT
% =========================================================================
config.output.saveCsv          = true;
config.output.outputDirectory  = '.';
config.output.showPlots        = true;    % model overview figures
config.output.showDailyPlots   = true;    % per-month daily-average figures
config.output.dailyPlotLayout  = 'grid';  % 'grid' or 'separate'
config.output.figureDirectory  = '';      % '' saves no PNG files
config.output.verbose          = true;
end
