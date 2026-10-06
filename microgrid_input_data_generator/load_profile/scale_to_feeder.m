function [feederLoad, feederMonthlyStats, feederInfo] = ...
         scale_to_feeder(hourlySubstationLoad, modelInfo, feederConfig)
%SCALE_TO_FEEDER  Scale a substation profile to a single distribution feeder.
%
%   [feederLoad, feederMonthlyStats, feederInfo] = ...
%       scale_to_feeder(hourlySubstationLoad, modelInfo)
%   [...] = scale_to_feeder(hourlySubstationLoad, modelInfo, feederConfig)
%
%   INPUTS
%     hourlySubstationLoad : 8760x1 from substation_load_profile  [MW]
%     modelInfo            : info struct from the same call
%     feederConfig         : (optional) struct overriding defaults below
%
%   OUTPUTS
%     feederLoad           : 8760x1 feeder demand [kW]
%     feederMonthlyStats   : monthly table
%     feederInfo           : diagnostics, scaling parameters, and the
%                            critical / non-critical split vectors
%
%   METHOD -----------------------------------------------------------------
%   The substation profile is taken as the SHAPE DONOR. Three operations
%   transform it to a feeder-level profile:
%
%   1. NORMALISATION. The substation series is divided by its mean,
%      producing a dimensionless shape with unit mean.
%
%   2. DIVERSITY CORRECTION. A feeder aggregates fewer customers than the
%      substation, so individual peaks coincide less, the evening spike is
%      relatively sharper, and the overnight trough is relatively deeper.
%      This is applied as a power-law exponent gamma > 1:
%
%          shapeCorrected(t) = shapeNormalised(t)^gamma / mean(...)
%
%      gamma = 1 reproduces the substation profile (no correction);
%      gamma > 1 sharpens peaks and deepens troughs while preserving the
%      mean. A value of 1.20 lowers the load factor from ~0.61 (substation)
%      to ~0.56 (feeder), consistent with published diversity factors for
%      rural distribution feeders with mixed residential and commercial load.
%
%   3. MAGNITUDE SCALING. The corrected shape is multiplied by a scale
%      factor so that the annual peak equals the target peak demand. The
%      target peak is the connected load PLUS the described exceedance
%      margin, because the user reports that demand occasionally exceeds
%      the total registered meter ratings by 0.2-0.3 MW during events or
%      simultaneous high-power appliance use.
%
%   CRITICAL LOAD SPLIT ------------------------------------------------------
%   The designated critical facilities are all connected to THIS feeder, so
%   the split is performed here rather than at substation level. Critical
%   demand is built deterministically from the per-facility schedules in
%   config.critical (see load_config.m and compute_critical_load.m) and is
%   treated as a SUBSET of the feeder total:
%
%       nonCritical(t) = feederLoad(t) - critical(t)
%
%   This replaces the earlier flat criticalLoadFraction, which applied the
%   same percentage at every hour and could not represent the fact that
%   critical load is nearly flat while total demand swings by a factor of
%   five across the day - the critical SHARE is therefore highest in the
%   overnight trough and lowest at the evening peak, which is precisely the
%   quantity that matters for backup sizing.
%
%   The output is in kW, not MW, because at feeder scale the numbers are
%   more readable in kW and HOMER expects kW input.

% ------------------------------------------------------------------------
% 0. Defaults
% ------------------------------------------------------------------------
if nargin < 3, feederConfig = struct(); end

defaultConfig = struct( ...
    'feederName',           'Feni feeder', ...
    'connectedLoadMW',      1.50,  ...   % sum of all meter ratings [MW]
    'exceedanceMarginMW',   0.25,  ...   % typical overshoot above connected load
    'diversityGamma',       1.20,  ...   % diversity correction exponent
    'outputUnits',          'kW',  ...   % 'kW' or 'MW'
    'saveCsv',              true,  ...
    'outputDirectory',      '.',   ...
    'showPlots',            true,  ...
    'showDailyPlots',       true,  ...
    'dailyPlotLayout',      'grid', ...
    'verbose',              true);

% NOTE: the former 'criticalLoadFraction' field has been REMOVED. Critical
% demand is no longer a flat percentage of feeder load; it is built from the
% per-facility schedules in config.critical (load_config.m). If an old
% script still passes criticalLoadFraction it is ignored with a warning.
if isfield(feederConfig, 'criticalLoadFraction')
    warning(['feederConfig.criticalLoadFraction is obsolete and has been ' ...
             'ignored. Critical load is now built from the per-facility ' ...
             'schedules in config.critical - edit those in load_config.m.']);
    feederConfig = rmfield(feederConfig, 'criticalLoadFraction');
end

fieldNames = fieldnames(defaultConfig);
for fieldIndex = 1:numel(fieldNames)
    if ~isfield(feederConfig, fieldNames{fieldIndex})
        feederConfig.(fieldNames{fieldIndex}) = defaultConfig.(fieldNames{fieldIndex});
    end
end

verbose       = feederConfig.verbose;
calendarData  = modelInfo.calendarData;
numberOfDays  = calendarData.numberOfDays;
numberOfHours = 24 * numberOfDays;

if numel(hourlySubstationLoad) ~= numberOfHours
    error(['hourlySubstationLoad has %d elements but the calendar covers ' ...
           '%d days (%d hours expected).'], ...
           numel(hourlySubstationLoad), numberOfDays, numberOfHours);
end

% ------------------------------------------------------------------------
% 1. Normalise to unit mean
% ------------------------------------------------------------------------
normalisedShape = hourlySubstationLoad(:) / mean(hourlySubstationLoad);

% ------------------------------------------------------------------------
% 2. Diversity correction
% ------------------------------------------------------------------------
diversityGamma  = feederConfig.diversityGamma;
correctedShape  = normalisedShape .^ diversityGamma;
correctedShape  = correctedShape / mean(correctedShape);   % restore unit mean

substationLoadFactor = mean(normalisedShape) / max(normalisedShape);
feederLoadFactor     = mean(correctedShape)  / max(correctedShape);

if verbose
    fprintf('\n=== Diversity correction ===\n');
    fprintf('  gamma              : %.3f\n', diversityGamma);
    fprintf('  substation LF      : %.3f\n', substationLoadFactor);
    fprintf('  feeder LF          : %.3f\n', feederLoadFactor);
    fprintf('  peak-to-mean ratio : %.3f -> %.3f\n', ...
            max(normalisedShape), max(correctedShape));
end

% ------------------------------------------------------------------------
% 3. Magnitude scaling
% ------------------------------------------------------------------------
targetPeakMW = feederConfig.connectedLoadMW + feederConfig.exceedanceMarginMW;

switch lower(feederConfig.outputUnits)
    case 'kw'
        unitMultiplier = 1000;
        unitLabel      = 'kW';
    case 'mw'
        unitMultiplier = 1;
        unitLabel      = 'MW';
    otherwise
        error('outputUnits must be ''kW'' or ''MW''.');
end

scaleFactor = targetPeakMW / max(correctedShape);
feederLoad  = correctedShape * scaleFactor * unitMultiplier;

% ------------------------------------------------------------------------
% 3b. Critical / non-critical split
% ------------------------------------------------------------------------
% Critical demand is deterministic and built from the facility schedules in
% config.critical. compute_critical_load always returns kW, so convert if
% the feeder is being reported in MW.
substationConfig = modelInfo.config;
[criticalLoadKW, facilityBreakdownKW] = ...
    compute_critical_load(substationConfig, calendarData);

if strcmpi(feederConfig.outputUnits, 'mw')
    criticalLoad = criticalLoadKW / 1000;
else
    criticalLoad = criticalLoadKW;
end

overrunHours = criticalLoad > feederLoad;
if any(overrunHours)
    warning(['Critical demand exceeds total feeder demand at %d of %d ' ...
             'hour(s) (max shortfall %.1f %s). Capping critical to the ' ...
             'feeder total at those hours so non-critical stays ' ...
             'non-negative. This means the feeder as scaled cannot supply ' ...
             'its own critical facilities - check connectedLoadMW against ' ...
             'the sum of critical facility ratings.'], ...
             sum(overrunHours), numberOfHours, ...
             max(criticalLoad - feederLoad), unitLabel);
    criticalLoad(overrunHours) = feederLoad(overrunHours);
end

nonCriticalLoad = feederLoad - criticalLoad;
criticalShareOfEnergy = sum(criticalLoad) / sum(feederLoad);
criticalShareByHour   = criticalLoad ./ feederLoad;

if verbose
    fprintf('\n=== Critical load split (feeder level) ===\n');
    fprintf('  facilities modelled  : %d\n', numel(substationConfig.critical));
    facilityNames = fieldnames(facilityBreakdownKW);
    for facilityIndex = 1:numel(facilityNames)
        thisSeries = facilityBreakdownKW.(facilityNames{facilityIndex});
        fprintf('    %-28s peak %7.1f kW, mean %7.1f kW\n', ...
                substationConfig.critical(facilityIndex).name, ...
                max(thisSeries), mean(thisSeries));
    end
    fprintf('  peak critical        : %8.1f %s\n', max(criticalLoad), unitLabel);
    fprintf('  mean critical        : %8.1f %s\n', mean(criticalLoad), unitLabel);
    fprintf('  min critical         : %8.1f %s\n', min(criticalLoad), unitLabel);
    fprintf('  critical energy share: %8.1f%%\n', 100*criticalShareOfEnergy);
    fprintf('  critical share range : %.1f%% (at feeder peak) to %.1f%% (at trough)\n', ...
            100*min(criticalShareByHour), 100*max(criticalShareByHour));
end

% ------------------------------------------------------------------------
% 4. Monthly statistics
% ------------------------------------------------------------------------
monthOfHour     = repelem(calendarData.monthOfDay, 24);
[uniqueMonths, ~, monthGroupIndex] = unique(monthOfHour);
daysInMonth     = [31 28 31 30 31 30 31 31 30 31 30 31]';

numberOfMonths  = numel(uniqueMonths);
Month           = uniqueMonths(:);
MeanDemand      = accumarray(monthGroupIndex, feederLoad, [], @mean);
PeakDemand      = accumarray(monthGroupIndex, feederLoad, [], @max);
MinDemand       = accumarray(monthGroupIndex, feederLoad, [], @min);
TotalEnergy     = accumarray(monthGroupIndex, feederLoad);
LoadFactor      = MeanDemand ./ PeakDemand;
DailyEnergy     = TotalEnergy ./ daysInMonth(uniqueMonths);

feederMonthlyStats = table(Month, MeanDemand, PeakDemand, MinDemand, ...
                           TotalEnergy, DailyEnergy, LoadFactor);
feederMonthlyStats.Properties.VariableNames = ...
    {'Month', ['Mean_' unitLabel], ['Peak_' unitLabel], ['Min_' unitLabel], ...
     ['Energy_' unitLabel 'h'], ['DailyEnergy_' unitLabel 'h'], 'LoadFactor'};

% Daily peaks for exceedance reporting
dailyPeakDemand = max(reshape(feederLoad, 24, numberOfDays), [], 1)';
connectedLoadInUnits = feederConfig.connectedLoadMW * unitMultiplier;
daysAboveConnected   = sum(dailyPeakDemand > connectedLoadInUnits);
hoursAboveConnected  = sum(feederLoad > connectedLoadInUnits);

% Info struct
feederInfo = struct();
feederInfo.annualMeanDemand        = mean(feederLoad);
feederInfo.annualPeakDemand        = max(feederLoad);
feederInfo.annualMinDemand         = min(feederLoad);
feederInfo.annualEnergy            = sum(feederLoad);
feederInfo.annualLoadFactor        = mean(feederLoad) / max(feederLoad);
feederInfo.connectedLoad           = connectedLoadInUnits;
feederInfo.targetPeak              = targetPeakMW * unitMultiplier;
feederInfo.diversityGamma          = diversityGamma;
feederInfo.scaleFactor             = scaleFactor;
feederInfo.criticalLoad            = criticalLoad;
feederInfo.nonCriticalLoad         = nonCriticalLoad;
feederInfo.facilityBreakdownKW     = facilityBreakdownKW;
feederInfo.peakCritical            = max(criticalLoad);
feederInfo.meanCritical            = mean(criticalLoad);
feederInfo.minCritical             = min(criticalLoad);
feederInfo.criticalEnergyShare     = criticalShareOfEnergy;
feederInfo.criticalShareByHour     = criticalShareByHour;
feederInfo.peakNonCritical         = max(nonCriticalLoad);
feederInfo.meanNonCritical         = mean(nonCriticalLoad);
feederInfo.dailyPeakDemand         = dailyPeakDemand;
feederInfo.daysAboveConnectedLoad  = daysAboveConnected;
feederInfo.hoursAboveConnectedLoad = hoursAboveConnected;
feederInfo.dailyPeakP50            = median(dailyPeakDemand);
feederInfo.dailyPeakP90            = simple_percentile(dailyPeakDemand, 90);
feederInfo.dailyPeakP95            = simple_percentile(dailyPeakDemand, 95);
feederInfo.unitLabel               = unitLabel;
feederInfo.calendarData            = calendarData;
feederInfo.feederConfig            = feederConfig;

% plot_daily_demand expects modelInfo.config.site.units/name.
% Keep the feeder settings separately in feederInfo.feederConfig.
feederInfo.config = struct();
feederInfo.config.site.units = unitLabel;
feederInfo.config.site.name  = feederConfig.feederName;

if verbose
    fprintf('\n=== %s - monthly statistics [%s] ===\n', ...
            feederConfig.feederName, unitLabel);
    disp(feederMonthlyStats);
    fprintf('=== Annual ===\n');
    fprintf('  mean demand         : %8.1f %s\n', feederInfo.annualMeanDemand, unitLabel);
    fprintf('  annual peak         : %8.1f %s\n', feederInfo.annualPeakDemand, unitLabel);
    fprintf('  minimum demand      : %8.1f %s\n', feederInfo.annualMinDemand, unitLabel);
    fprintf('  annual energy       : %8.1f %sh\n', feederInfo.annualEnergy, unitLabel);
    fprintf('  load factor         : %8.3f\n', feederInfo.annualLoadFactor);
    fprintf('  connected load      : %8.1f %s\n', connectedLoadInUnits, unitLabel);
    fprintf('  daily peak (median) : %8.0f %s\n', feederInfo.dailyPeakP50, unitLabel);
    fprintf('  daily peak (P95)    : %8.0f %s\n', feederInfo.dailyPeakP95, unitLabel);
    fprintf('  days peak > conn.   : %8d of %d (%.0f%%)\n', ...
            daysAboveConnected, numberOfDays, 100*daysAboveConnected/numberOfDays);
    fprintf('  hours > conn. load  : %8d (%.1f%%)\n', ...
            hoursAboveConnected, 100*hoursAboveConnected/numberOfHours);
end

% ------------------------------------------------------------------------
% 5. CSV output
% ------------------------------------------------------------------------
if feederConfig.saveCsv
    outputDirectory = feederConfig.outputDirectory;
    if ~isempty(outputDirectory) && exist(outputDirectory,'dir') ~= 7
        mkdir(outputDirectory);
    end

    hourNumber       = (1:numberOfHours)';
    hourlyDateNumber = repelem(calendarData.dateNumber, 24) + ...
                       repmat((0:23)'/24, numberOfDays, 1);

    % Optimizer loader expects MM/dd/yyyy HH:mm when the CSV column is text.
    datetimeStrings = cellstr(datestr(hourlyDateNumber,'mm/dd/yyyy HH:MM'));

    % Match the published optimizer input precision while preserving exact
    % critical + non-critical = total balance after rounding.
    totalLoadForCsv       = round(feederLoad, 3);
    criticalLoadForCsv    = round(criticalLoad, 3);
    nonCriticalLoadForCsv = round(totalLoadForCsv - criticalLoadForCsv, 3);

    feederOutputTable = table( ...
        datetimeStrings, hourNumber, ...
        nonCriticalLoadForCsv, criticalLoadForCsv, totalLoadForCsv, ...
        'VariableNames', {'datetime','hour', ...
                          ['non_critical_load_' unitLabel], ...
                          ['critical_load_' unitLabel], ...
                          ['total_load_' unitLabel]});
    writetable(feederOutputTable, ...
        fullfile(outputDirectory, 'hourly_feeder_load_profile_spliting.csv'));
    writetable(feederMonthlyStats, ...
        fullfile(outputDirectory, 'feeder_load_profile_monthly.csv'));
    if verbose
        fprintf('\n  written: hourly_feeder_load_profile_spliting.csv\n');
        fprintf('           feeder_load_profile_monthly.csv\n');
    end
end

% ------------------------------------------------------------------------
% 6. Figures
% ------------------------------------------------------------------------
if feederConfig.showPlots
    plot_feeder_overview(feederLoad, criticalLoad, nonCriticalLoad, ...
                         dailyPeakDemand, feederMonthlyStats, ...
                         calendarData, feederConfig, feederInfo, ...
                         uniqueMonths, unitLabel);
end

if feederConfig.showDailyPlots
    if exist('plot_daily_demand','file') ~= 2
        warning(['plot_daily_demand.m was not found on the MATLAB path, so ' ...
                 'the per-month daily-average figures were skipped.']);
    else
        feederInfo.dailyDemandTable = plot_daily_demand(feederLoad, feederInfo, ...
            'Layout', feederConfig.dailyPlotLayout);
    end
end
end

% =========================================================================
function plot_feeder_overview(feederLoad, criticalLoad, nonCriticalLoad, ...
    dailyPeakDemand, feederMonthlyStats, calendarData, feederConfig, ...
    feederInfo, uniqueMonths, unitLabel)

numberOfDays  = calendarData.numberOfDays;
numberOfHours = numel(feederLoad);
connectedLoadInUnits = feederConfig.connectedLoadMW * ...
    (strcmpi(feederConfig.outputUnits,'kw')*1000 + ...
     strcmpi(feederConfig.outputUnits,'mw')*1);

meanDemandByMonth = feederMonthlyStats{:,2};
peakDemandByMonth = feederMonthlyStats{:,3};

figure('Position',[80 80 1150 800],'Color','w');

% Annual chronology
subplot(2,2,1);
plot(feederLoad, 'LineWidth',0.3, 'Color',[0.25 0.35 0.55]); hold on; grid on;
yline(connectedLoadInUnits, '--r', 'Connected load', 'LineWidth',1.2);
yline(feederInfo.targetPeak, ':r', 'Target peak', 'LineWidth',1.0);
xlabel('Hour of year'); ylabel(sprintf('Demand [%s]', unitLabel));
title(sprintf('%s - annual load profile', feederConfig.feederName));
xlim([1 numberOfHours]); ylim([0 feederInfo.targetPeak*1.15]);

% Daily peak distribution
subplot(2,2,2);
histogram(dailyPeakDemand, 30, 'FaceColor',[0.30 0.45 0.65], ...
          'EdgeColor','none'); hold on; grid on;
xline(connectedLoadInUnits, '--r', 'Connected load', 'LineWidth',1.5);
xlabel(sprintf('Daily peak demand [%s]', unitLabel));
ylabel('Number of days');
title(sprintf('Daily peak distribution (%.0f%% below %.0f %s)', ...
    100*(1-feederInfo.daysAboveConnectedLoad/numberOfDays), ...
    connectedLoadInUnits, unitLabel));

% Monthly mean and peak
subplot(2,2,3);
bar(uniqueMonths, meanDemandByMonth, 'FaceColor',[0.30 0.45 0.65]); hold on;
plot(uniqueMonths, peakDemandByMonth, 'o-', 'Color',[0.80 0.30 0.20], ...
     'LineWidth',1.5);
yline(connectedLoadInUnits, '--r', 'Connected', 'LineWidth',1.0);
grid on; xlabel('Month'); xticks(uniqueMonths);
ylabel(sprintf('Demand [%s]', unitLabel));
title('Monthly mean and peak demand');
legend({'Mean','Peak','Connected load'}, 'Location','south','FontSize',8);

% Heat map
subplot(2,2,4);
imagesc(1:numberOfDays, 0:23, reshape(feederLoad, 24, numberOfDays));
set(gca,'YDir','normal'); colorbar;
xlabel('Day of year'); ylabel('Hour of day');
title(sprintf('Hourly demand [%s]', unitLabel));

% Representative days
figure('Position',[120 120 900 420],'Color','w');
loadMatrix = reshape(feederLoad, 24, numberOfDays);
monthOfDay = calendarData.monthOfDay;

selectedMonths = [1 3 5 7 10 12];
monthNameList = {'Jan','Feb','Mar','Apr','May','Jun', ...
                 'Jul','Aug','Sep','Oct','Nov','Dec'};
colours = lines(numel(selectedMonths));
for plotIndex = 1:numel(selectedMonths)
    selectedDays = (monthOfDay == selectedMonths(plotIndex));
    meanDailyCurve = mean(loadMatrix(:,selectedDays), 2);
    plot(0:23, meanDailyCurve, '-', 'LineWidth',1.8, ...
         'Color', colours(plotIndex,:)); hold on;
end
yline(connectedLoadInUnits, '--r', 'Connected load', 'LineWidth',1.2);
grid on; xlabel('Hour of day'); ylabel(sprintf('Demand [%s]', unitLabel));
title(sprintf('%s - mean daily curve by month', feederConfig.feederName));
legend([monthNameList(selectedMonths), {'Connected'}], ...
       'Location','northwest','FontSize',8);
xlim([0 23]); xticks(0:3:23);

% ---- Critical / non-critical split ----
figure('Position',[160 160 1150 420],'Color','w');

subplot(1,2,1);
criticalMatrix    = reshape(criticalLoad,    24, numberOfDays);
nonCriticalMatrix = reshape(nonCriticalLoad, 24, numberOfDays);
meanCriticalCurve    = mean(criticalMatrix, 2);
meanNonCriticalCurve = mean(nonCriticalMatrix, 2);
areaHandle = area(0:23, [meanCriticalCurve, meanNonCriticalCurve]);
areaHandle(1).FaceColor = [0.80 0.35 0.25];
areaHandle(2).FaceColor = [0.45 0.60 0.80];
grid on; xlabel('Hour of day'); ylabel(sprintf('Demand [%s]', unitLabel));
title('Mean daily split, annual average');
legend({'Critical','Non-critical'}, 'Location','northwest','FontSize',8);
xlim([0 23]); xticks(0:3:23);

subplot(1,2,2);
plot(0:23, 100*mean(criticalMatrix ./ reshape(feederLoad,24,numberOfDays), 2), ...
     'LineWidth',1.8, 'Color',[0.80 0.35 0.25]);
grid on; xlabel('Hour of day'); ylabel('Critical share of demand [%]');
title(sprintf('Critical share by hour (annual mean %.1f%%)', ...
      100*feederInfo.criticalEnergyShare));
xlim([0 23]); xticks(0:3:23);
end

% =========================================================================
function percentileValue = simple_percentile(dataVector, percentileWanted)
sortedData     = sort(dataVector(:));
numberOfPoints = numel(sortedData);
if numberOfPoints == 1, percentileValue = sortedData; return; end
positionVector  = 100*((1:numberOfPoints)' - 0.5)/numberOfPoints;
percentileValue = interp1(positionVector, sortedData, percentileWanted, ...
                          'linear', 'extrap');
end
