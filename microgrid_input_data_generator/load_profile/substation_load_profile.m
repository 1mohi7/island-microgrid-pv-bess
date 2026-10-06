function [hourlyLoad, monthlyStatsTable, modelInfo] = substation_load_profile(config)
%SUBSTATION_LOAD_PROFILE  Hourly load profile from archetype blending.
%
%   [hourlyLoad, monthlyStatsTable, modelInfo] = substation_load_profile()
%   [...] = substation_load_profile(config)
%
%   hourlyLoad        : (24*numberOfDays) x 1 demand, in config.site.units
%   monthlyStatsTable : monthly mean / peak / min / energy / load factor
%   modelInfo         : archetypes, shape matrix, warmth weights, calendar
%
%   Called with no arguments it loads load_config, runs the model, prints the
%   statistics, and draws every figure including the per-month daily-average
%   plots. All parameters live in load_config.m - nothing is hardcoded here.
%
%   MODEL ------------------------------------------------------------------
%   Each DAY is a convex blend of a hot and a cold archetype daily curve,
%   using that day's own warmth weight, plus any additive overlays:
%
%     S(d,h) = w(d)*hotCurve(h) + (1-w(d))*coldCurve(h)
%              + sum over overlays of magnitude(d)*shape(h)
%
%   followed by a day-type modifier and a two-level stochastic component.
%
%   Blending rather than scaling is deliberate: it interpolates the SHAPE as
%   well as the level, reproducing the steeper post-peak evening decay seen
%   in cold months. A single multiplicative seasonal factor cannot do this -
%   it produces a low summer curve with summer's slow evening decay.
%
%   Warmth weights are DAILY and derived from measured temperature, so warm
%   days in a cool month and cool days in a warm month appear explicitly
%   rather than being absorbed into random noise.
%
%   Overlays are ADDITIVE because block loads such as irrigation pumping
%   switch on largely independently of the underlying demand.

if nargin < 1 || isempty(config), config = load_config(); end
verbose = config.output.verbose;

% ------------------------------------------------------------------------
% 1. Warmth weights and calendar
% ------------------------------------------------------------------------
if verbose, fprintf('\n=== %s ===\n', config.site.name); end
[dailyWarmthWeight, calendarData, monthlyTemperatureTable] = ...
    compute_warmth_weights(config);

numberOfDays  = calendarData.numberOfDays;
numberOfHours = 24 * numberOfDays;

% ------------------------------------------------------------------------
% 2. Archetype curves
% ------------------------------------------------------------------------
if isfield(config.archetype,'archetypeFileName') && ...
   ~isempty(config.archetype.archetypeFileName)
    archetypeFileName = config.archetype.archetypeFileName;
    if exist(archetypeFileName,'file') ~= 2
        error('Archetype file not found: %s', archetypeFileName);
    end
    archetypeData = readmatrix(archetypeFileName);
    if size(archetypeData,1) ~= 24 || size(archetypeData,2) < 3
        error(['Archetype file must contain 24 rows and at least 3 columns, ' ...
               'ordered [hour, hot, cold].']);
    end
    hotArchetypeCurve  = archetypeData(:,2);
    coldArchetypeCurve = archetypeData(:,3);
    if verbose
        fprintf('  archetype curves loaded from %s\n', archetypeFileName);
    end
else
    hotArchetypeCurve  = config.archetype.hotCurve(:);
    coldArchetypeCurve = config.archetype.coldCurve(:);
end

if numel(hotArchetypeCurve) ~= 24 || numel(coldArchetypeCurve) ~= 24
    error('Both archetype curves must contain exactly 24 elements.');
end
if any(hotArchetypeCurve < coldArchetypeCurve)
    warning(['The hot archetype falls below the cold archetype at %d hour(s). ' ...
             'Check that the two curves have not been swapped.'], ...
             sum(hotArchetypeCurve < coldArchetypeCurve));
end

% ------------------------------------------------------------------------
% 3. Additive overlays
% ------------------------------------------------------------------------
overlayByDay = zeros(24, numberOfDays);
if isfield(config,'overlay') && ~isempty(config.overlay)
    for overlayIndex = 1:numel(config.overlay)
        thisOverlay = config.overlay(overlayIndex);
        if numel(thisOverlay.hourlyShape) ~= 24
            error('Overlay "%s": hourlyShape must contain 24 elements.', ...
                  thisOverlay.overlayName);
        end
        if numel(thisOverlay.activeMonths) ~= numel(thisOverlay.monthlyMagnitude)
            error(['Overlay "%s": activeMonths and monthlyMagnitude must be ' ...
                   'the same length.'], thisOverlay.overlayName);
        end
        for monthPosition = 1:numel(thisOverlay.activeMonths)
            selectedDays = (calendarData.monthOfDay == ...
                            thisOverlay.activeMonths(monthPosition));
            overlayByDay(:, selectedDays) = overlayByDay(:, selectedDays) + ...
                thisOverlay.monthlyMagnitude(monthPosition) * ...
                thisOverlay.hourlyShape(:);
        end
        if verbose
            fprintf('  overlay "%s": months [%s], peak magnitude %.2f %s\n', ...
                    thisOverlay.overlayName, num2str(thisOverlay.activeMonths), ...
                    max(thisOverlay.monthlyMagnitude), config.site.units);
        end
    end
end

% ------------------------------------------------------------------------
% 4. Deterministic build
% ------------------------------------------------------------------------
dailyLoadMatrix = (hotArchetypeCurve - coldArchetypeCurve) * dailyWarmthWeight(:)' ...
                + coldArchetypeCurve * ones(1, numberOfDays) ...
                + overlayByDay;

dayTypeNames       = fieldnames(config.dayType);
modifiedDayCount   = 0;
for dayTypeIndex = 1:numel(dayTypeNames)
    thisDayName     = dayTypeNames{dayTypeIndex};
    thisModifier    = config.dayType.(thisDayName)(:);
    if numel(thisModifier) ~= 24
        error('Day-type modifier "%s" must contain 24 elements.', thisDayName);
    end
    selectedDays = strcmp(calendarData.dayName, thisDayName);
    dailyLoadMatrix(:, selectedDays) = dailyLoadMatrix(:, selectedDays) .* thisModifier;
    modifiedDayCount = modifiedDayCount + sum(selectedDays);
end
if verbose && modifiedDayCount > 0
    fprintf('  day-type modifiers applied to %d of %d days\n', ...
            modifiedDayCount, numberOfDays);
end

hourlyLoad = dailyLoadMatrix(:);

% Mean deterministic daily curve per month, for plotting and reuse
uniqueMonths      = unique(calendarData.monthOfDay);
monthlyShapeMatrix = zeros(24, numel(uniqueMonths));
for monthIndex = 1:numel(uniqueMonths)
    selectedDays = (calendarData.monthOfDay == uniqueMonths(monthIndex));
    monthlyShapeMatrix(:,monthIndex) = mean(dailyLoadMatrix(:, selectedDays), 2);
end

% ------------------------------------------------------------------------
% 5. Stochastic component
% ------------------------------------------------------------------------
% Two levels. The daily term represents NON-WEATHER variation only, since
% weather is already explicit in dailyWarmthWeight. The AR(1) hourly
% residual avoids the implausible hour-to-hour jumps of independent draws.
stochasticConfig = config.stochastic;
rng(stochasticConfig.randomSeed, 'twister');

dailyNoise = repelem(randn(numberOfDays,1) * stochasticConfig.dailyStdDev, 24);
whiteNoise = randn(numberOfHours,1) * stochasticConfig.hourlyStdDev * ...
             sqrt(1 - stochasticConfig.arCoefficient^2);
hourlyNoise = filter(1, [1 -stochasticConfig.arCoefficient], whiteNoise);

hourlyLoad = hourlyLoad .* (1 + dailyNoise) .* (1 + hourlyNoise);
hourlyLoad = max(hourlyLoad, stochasticConfig.floorFraction * mean(hourlyLoad));

% ------------------------------------------------------------------------
% 6. Monthly statistics
% ------------------------------------------------------------------------
monthPerHour = repelem(calendarData.monthOfDay, 24);
[uniqueMonths, ~, monthGroupIndex] = unique(monthPerHour);

Month      = uniqueMonths(:);
MeanLoad   = accumarray(monthGroupIndex, hourlyLoad, [], @mean);
PeakLoad   = accumarray(monthGroupIndex, hourlyLoad, [], @max);
MinLoad    = accumarray(monthGroupIndex, hourlyLoad, [], @min);
TotalEnergy = accumarray(monthGroupIndex, hourlyLoad);
LoadFactor = MeanLoad ./ PeakLoad;

MeanWarmthWeight = zeros(numel(uniqueMonths),1);
for monthIndex = 1:numel(uniqueMonths)
    selectedDays = (calendarData.monthOfDay == uniqueMonths(monthIndex));
    MeanWarmthWeight(monthIndex) = mean(dailyWarmthWeight(selectedDays));
end

unitLabel = config.site.units;
monthlyStatsTable = table(Month, MeanWarmthWeight, MeanLoad, PeakLoad, ...
                          MinLoad, TotalEnergy, LoadFactor);
monthlyStatsTable.Properties.VariableNames = {'Month','MeanWarmthWeight', ...
    ['Mean_' unitLabel], ['Peak_' unitLabel], ['Min_' unitLabel], ...
    ['Energy_' unitLabel 'h'], 'LoadFactor'};

modelInfo = struct();
modelInfo.annualMeanLoad   = mean(hourlyLoad);
modelInfo.annualPeakLoad   = max(hourlyLoad);
modelInfo.annualMinLoad    = min(hourlyLoad);
modelInfo.annualEnergy     = sum(hourlyLoad);
modelInfo.annualLoadFactor = mean(hourlyLoad)/max(hourlyLoad);
modelInfo.spareHeadroomPct = 100*(1 - max(hourlyLoad)/config.site.capacity);
modelInfo.hotArchetypeCurve  = hotArchetypeCurve;
modelInfo.coldArchetypeCurve = coldArchetypeCurve;
modelInfo.monthlyShapeMatrix = monthlyShapeMatrix;
modelInfo.normalisedShapeMatrix = monthlyShapeMatrix / mean(monthlyShapeMatrix(:));
modelInfo.dailyWarmthWeight       = dailyWarmthWeight;
modelInfo.calendarData            = calendarData;
modelInfo.monthlyTemperatureTable = monthlyTemperatureTable;
modelInfo.config                  = config;

if verbose
    fprintf('\n=== Monthly load statistics ===\n');
    disp(monthlyStatsTable);
    fprintf('=== Annual ===\n');
    fprintf('  mean demand    : %8.2f %s\n', modelInfo.annualMeanLoad, unitLabel);
    fprintf('  peak demand    : %8.2f %s  (%.0f%% of %.1f %s rating)\n', ...
            modelInfo.annualPeakLoad, unitLabel, ...
            100*modelInfo.annualPeakLoad/config.site.capacity, ...
            config.site.capacity, unitLabel);
    fprintf('  minimum demand : %8.2f %s\n', modelInfo.annualMinLoad, unitLabel);
    fprintf('  total energy   : %8.2f %sh\n', modelInfo.annualEnergy, unitLabel);
    fprintf('  load factor    : %8.3f\n', modelInfo.annualLoadFactor);
    fprintf('  spare headroom : %8.1f%%\n', modelInfo.spareHeadroomPct);
end

if modelInfo.annualPeakLoad > config.site.capacity
    warning(['Synthesised peak (%.2f %s) exceeds the stated rating (%.2f %s). ' ...
             'Check the archetype levels or the overlay magnitudes.'], ...
            modelInfo.annualPeakLoad, unitLabel, config.site.capacity, unitLabel);
end

% ------------------------------------------------------------------------
% 7. CSV output
% ------------------------------------------------------------------------
% NOTE: the critical / non-critical split is NOT done here. The critical
% facilities (clinic, water pumps, comms tower, cyclone-shelter-cum-school)
% are all connected to a single distribution FEEDER, not spread across the
% whole substation, so splitting the substation total would be physically
% wrong. The split is performed in scale_to_feeder.m against the feeder
% profile. See config.critical in load_config.m for the facility list.
if config.output.saveCsv
    outputDirectory = config.output.outputDirectory;
    if ~isempty(outputDirectory) && exist(outputDirectory,'dir') ~= 7
        mkdir(outputDirectory);
    end
    hourNumber      = (1:numberOfHours)';
    hourlyDateNumber = repelem(calendarData.dateNumber, 24) + ...
                       repmat((0:23)'/24, numberOfDays, 1);
    hourlyOutputTable = table(hourNumber, ...
        cellstr(datestr(hourlyDateNumber,'yyyy-mm-dd HH:MM')), hourlyLoad, ...
        'VariableNames', {'hour','datetime',['load_' unitLabel]});
    writetable(hourlyOutputTable, ...
        fullfile(outputDirectory,'load_profile_hourly.csv'));
    writetable(monthlyStatsTable, ...
        fullfile(outputDirectory,'load_profile_monthly.csv'));
    if verbose
        fprintf('\n  written: %s\n           %s\n', ...
                fullfile(outputDirectory,'load_profile_hourly.csv'), ...
                fullfile(outputDirectory,'load_profile_monthly.csv'));
    end
end

% ------------------------------------------------------------------------
% 8. Figures
% ------------------------------------------------------------------------
if config.output.showPlots
    plot_model_overview(hourlyLoad, monthlyShapeMatrix, monthlyStatsTable, ...
                        dailyWarmthWeight, calendarData, config, uniqueMonths);
end

if config.output.showDailyPlots
    if exist('plot_daily_demand','file') ~= 2
        warning(['plot_daily_demand.m was not found on the MATLAB path, so ' ...
                 'the per-month daily-average figures were skipped.']);
    else
        modelInfo.dailyDemandTable = plot_daily_demand(hourlyLoad, modelInfo, ...
            'Layout',  config.output.dailyPlotLayout, ...
            'SaveDir', config.output.figureDirectory, ...
            'SaveCSV', config.output.saveCsv);
    end
end
end

% =========================================================================
function plot_model_overview(hourlyLoad, monthlyShapeMatrix, monthlyStatsTable, ...
                             dailyWarmthWeight, calendarData, config, uniqueMonths)
%PLOT_MODEL_OVERVIEW  Four-panel summary plus the annual chronology.
unitLabel    = config.site.units;
numberOfDays = calendarData.numberOfDays;
meanLoadByMonth = monthlyStatsTable{:,3};
peakLoadByMonth = monthlyStatsTable{:,4};

figure('Position',[80 80 1150 800],'Color','w');

subplot(2,2,1);
selectedMonths = ismember(uniqueMonths, [5 7 10 12]);
if ~any(selectedMonths), selectedMonths = true(size(uniqueMonths)); end
plot(0:23, monthlyShapeMatrix(:,selectedMonths), 'LineWidth',1.8); grid on;
legend(cellstr(datestr(datenum(2000,uniqueMonths(selectedMonths),1),'mmm')), ...
       'Location','northwest','FontSize',8);
xlabel('Hour of day'); ylabel(sprintf('Demand [%s]', unitLabel));
title('Mean daily curve by month'); xlim([0 23]); xticks(0:3:23);

subplot(2,2,2);
plot(1:numberOfDays, dailyWarmthWeight, 'LineWidth',0.8); grid on;
xlabel('Day of year'); ylabel('Warmth weight');
title('Daily warmth weight from measured temperature');
xlim([1 numberOfDays]); ylim([0 config.warmth.maximumWarmthWeight*1.05]);

subplot(2,2,3);
yyaxis left
bar(uniqueMonths, meanLoadByMonth, 'FaceColor',[0.30 0.45 0.65]); hold on;
plot(uniqueMonths, peakLoadByMonth, 'o-', 'LineWidth',1.5);
ylabel(sprintf('Demand [%s]', unitLabel));
yyaxis right
plot(uniqueMonths, monthlyStatsTable.MeanWarmthWeight, 's--', 'LineWidth',1.2);
ylabel('Mean warmth weight');
ylim([0 config.warmth.maximumWarmthWeight*1.05]);
grid on; xlabel('Month'); xticks(uniqueMonths);
title('Monthly mean, peak and warmth weight');
legend({'Mean','Peak','Warmth weight'}, 'Location','south','FontSize',8);

subplot(2,2,4);
imagesc(1:numberOfDays, 0:23, reshape(hourlyLoad,24,numberOfDays));
set(gca,'YDir','normal'); colorbar;
xlabel('Day of year'); ylabel('Hour of day');
title(sprintf('Hourly demand [%s]', unitLabel));

figure('Position',[120 120 1150 340],'Color','w');
plot(hourlyLoad,'LineWidth',0.3,'Color',[0.25 0.35 0.55]); grid on; hold on;
yline(config.site.capacity,'--r','Rating','LineWidth',1.2);
xlabel('Hour of year'); ylabel(sprintf('Demand [%s]', unitLabel));
title(sprintf('%s - annual chronological load profile', config.site.name));
xlim([1 numel(hourlyLoad)]); ylim([0 config.site.capacity*1.05]);
end
