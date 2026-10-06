function [gridAvailability, outageCause, statistics] = ...
            loadshedding_schedule_1_year(scenarioOrParameters, randomSeed)
% LOADSHEDDING_SCHEDULE_1_YEAR  One year of grid availability for one 11 kV feeder.
%
%   [gridAvailability, outageCause, statistics] = loadshedding_schedule_1_year()
%   [...] = loadshedding_schedule_1_year('design')
%   [...] = loadshedding_schedule_1_year('test',   seed)
%   [...] = loadshedding_schedule_1_year('stress', seed)
%   [...] = loadshedding_schedule_1_year(parameterStruct)
%
%   Three independent outage processes, combined with a precedence rule:
%
%     1. Deficit load shedding  - rostered feeder-block switching driven by
%                                 national generation shortfall. Whole-hour
%                                 blocks of 1 or 2 h, placed by an hour-of-day
%                                 deficit weight (evening-peak heavy). Daily
%                                 totals of 4-7 h are more likely in the hot
%                                 and monsoon months.
%     2. Planned maintenance    - announced spring daytime line work, whole
%                                 substation, half-day scale.
%     3. Transmission fault     - storm, tree fall or line failure. Poisson
%                                 arrivals concentrated in the pre-monsoon and
%                                 monsoon months. Two tiers: ordinary faults
%                                 clear within a few hours of the storm
%                                 passing, while a rare severe or flood-related
%                                 event runs for days. No hard duration cap.
%
%   Precedence: when a fault or maintenance outage is active there is nothing
%   to ration, so deficit shedding is suppressed for those hours.
%
%   OUTPUTS
%     gridAvailability  8760x1  1 = feeder supplied, 0 = no supply.
%     outageCause       8760x1  0 = available, 1 = deficit shedding,
%                               2 = planned maintenance, 3 = transmission fault.
%     statistics        struct  daily, monthly and annual summaries.
%
%   Also writes a three-column CSV (default loadshedding_schedule_1_year_with_status_flag.csv):
%   hour (1 to 8760), grid_available (1 supplied, 0 out), and outage_cause
%   (none | shedding | maintenance | fault). The cause tag is exported so the
%   ENS split by cause is reproducible from the published data.
%
%   DESIGN AND TEST SPLIT. The severe tier is OFF by default, so the year
%   returned is a design year: the microgrid is sized against it without a
%   rare multi-day event steering the result. Switch the tier on and vary the
%   seed to generate test years, and check how the already-fixed design holds
%   up against conditions it was not sized for. Use shedding_scenario to build
%   the three parameter sets, or pass the scenario name straight in:
%
%       [availabilityDesign, ~, statsDesign] = loadshedding_schedule_1_year('design');
%       [availabilityTest,   ~, statsTest]   = loadshedding_schedule_1_year('test', 101);
%
%   Set parameters.verbose and parameters.makePlots to false when looping over
%   many seeds, otherwise every year prints a table and opens three figures.
%
%   Site: Latifpur substation, Dagonbhuiyan, Feni.

if nargin < 1 || isempty(scenarioOrParameters)
    scenarioOrParameters = 'design';
end
if nargin < 2
    randomSeed = [];
end

if ischar(scenarioOrParameters) || isstring(scenarioOrParameters)
    parameters = shedding_scenario(char(scenarioOrParameters), randomSeed);
else
    parameters = scenarioOrParameters;
    if ~isempty(randomSeed)
        parameters.randomSeed = randomSeed;
    end
end
rng(parameters.randomSeed);

% ---------------------------------------------------------------- calendar
daysInMonth      = [31 28 31 30 31 30 31 31 30 31 30 31];
numberOfDays     = sum(daysInMonth);
hoursPerDay      = 24;
totalHours       = numberOfDays * hoursPerDay;
monthOfDay       = repelem(1:12, daysInMonth);
firstDayOfMonth  = cumsum([0 daysInMonth(1:end-1)]) + 1;

sheddingMask          = false(numberOfDays, hoursPerDay);
transmissionFaultSeries = false(totalHours, 1);   % chronological, see note below
maintenanceMask       = false(numberOfDays, hoursPerDay);
requestedBudgetHours  = zeros(numberOfDays, 1);

% ------------------------------------------------- 1. deficit load shedding
for dayIndex = 1:numberOfDays
    monthIndex = monthOfDay(dayIndex);

    if rand < parameters.probabilityNoSheddingDay(monthIndex)
        continue                                    % all feeders on today
    end

    % Daily budget: lognormal about the monthly mean, capped, rounded to whole
    % hours. The spread is month-dependent, so the hot and monsoon months
    % produce more of the long 4-7 hour days without shifting the typical day.
    budgetHours = parameters.meanSheddingHoursPerSheddingDay(monthIndex) * ...
                  exp(parameters.sheddingBudgetLogSigma(monthIndex)*randn - ...
                      0.5*parameters.sheddingBudgetLogSigma(monthIndex)^2);
    budgetHours = round(min(max(budgetHours, 0), ...
                            parameters.maximumDailySheddingHours));
    if budgetHours < parameters.minimumBlockDuration
        continue
    end
    requestedBudgetHours(dayIndex) = budgetHours;

    if any(monthIndex == parameters.irrigationMonths)
        deficitWeight = parameters.deficitWeightIrrigationSeason;
    else
        deficitWeight = parameters.deficitWeightDrySeason;
    end

    sheddingMask(dayIndex,:) = place_shedding_blocks(budgetHours, ...
                                    deficitWeight, parameters);
end

% ------------------------------------------------------ 2. planned maintenance
for eventIndex = 1:parameters.maintenanceEventsPerYear
    monthIndex = parameters.maintenanceMonths( ...
                    randi(numel(parameters.maintenanceMonths)));
    dayIndex   = firstDayOfMonth(monthIndex) + randi(daysInMonth(monthIndex)) - 1;
    startHour  = parameters.maintenanceStartHour + randi([-1 1]);
    duration   = parameters.maintenanceDuration + randi([-1 1]);
    endHour    = min(hoursPerDay, startHour + duration - 1);
    maintenanceMask(dayIndex, startHour:endHour) = true;
end

% -------------------------------------------------- 3. transmission faults
faultDurations  = [];
faultIsSevere   = [];
for monthIndex = 1:12
    numberOfEvents = poisson_sample(parameters.faultEventsPerMonth(monthIndex));
    for eventIndex = 1:numberOfEvents
        dayIndex   = firstDayOfMonth(monthIndex) + ...
                     randi(daysInMonth(monthIndex)) - 1;
        startHour  = randi(hoursPerDay);

        % Two tiers, both shifted Weibull. The floor covers switching, fault
        % location and crew travel before any repair begins; the Weibull term
        % is the repair itself.
        %
        %   Ordinary: crews clear the line within a few hours of the storm
        %             passing. Median around 6-7 h, with an unbounded tail for
        %             the harder faults.
        %   Severe:   cyclone damage or flooding, where access itself is the
        %             constraint. Days rather than hours. Rare, and confined
        %             to the storm and flood months.
        isSevere = parameters.includeSevereFaults && ...
                   rand < parameters.severeFaultProbability(monthIndex);
        if isSevere
            duration = parameters.minimumSevereFaultDuration + ...
                       parameters.severeFaultDurationScale * ...
                       (-log(rand))^(1/parameters.severeFaultDurationShape);
        else
            duration = parameters.minimumFaultDuration + ...
                       parameters.faultDurationScale * ...
                       (-log(rand))^(1/parameters.faultDurationShape);
        end

        % No physical cap on duration. The limit below is a numerical guard
        % against a pathological draw, not a modelling assumption; it binds on
        % roughly one event in ten thousand.
        duration = min(max(round(duration), parameters.minimumFaultDuration), ...
                       parameters.absoluteFaultDurationLimit);

        faultDurations(end+1) = duration;  %#ok<AGROW>
        faultIsSevere(end+1)  = isSevere;  %#ok<AGROW>

        % Faults run continuously and may cross midnight, so they are written
        % into a chronological 8760x1 vector. Do NOT linear-index the
        % day-by-hour matrix here: MATLAB stores column-major, so consecutive
        % linear indices step down DAYS within one hour column rather than
        % along hours within a day, which silently smears one long outage
        % across many days at the same clock hour.
        startIndex = (dayIndex-1)*hoursPerDay + startHour;
        endIndex   = min(totalHours, startIndex + duration - 1);
        transmissionFaultSeries(startIndex:endIndex) = true;
    end
end
transmissionFaultMask = reshape(transmissionFaultSeries, hoursPerDay, ...
                                numberOfDays).';
faultIsSevere = logical(faultIsSevere);

% ------------------------------------------------------------- precedence
% A day touched by a fault or a maintenance shutdown sees no deficit shedding
% at all, not merely during the outage hours. Operationally the feeder has
% already taken its share of the shortfall, so the control room rosters the
% remaining shedding onto the other feeders once supply is restored.
totalOutageMask = transmissionFaultMask | maintenanceMask;

sheddingHoursBeforePrecedence = sum(sheddingMask(:));
if parameters.suppressSheddingOnOutageDays
    outageDay = any(totalOutageMask, 2);
    sheddingMask(outageDay, :) = false;
    numberOfSuppressedDays = sum(outageDay);
else
    sheddingMask(totalOutageMask) = false;
    numberOfSuppressedDays = 0;
end
sheddingHoursSuppressed = sheddingHoursBeforePrecedence - sum(sheddingMask(:));

% ---------------------------------------------------------------- assemble
gridAvailability = ones(numberOfDays, hoursPerDay);
gridAvailability(sheddingMask | totalOutageMask) = 0;

outageCause = zeros(numberOfDays, hoursPerDay);
outageCause(sheddingMask)          = 1;
outageCause(maintenanceMask)       = 2;
outageCause(transmissionFaultMask) = 3;   % fault overrides maintenance

gridAvailability = reshape(gridAvailability.', totalHours, 1);
outageCause      = reshape(outageCause.',      totalHours, 1);

% ---------------------------------------------------------------- statistics
% Count the FINAL mutually exclusive cause tags, not the raw masks. A fault
% overrides maintenance in outageCause, so overlapping maintenance hours must
% not be double-counted in the annual/monthly totals.
effectiveMaintenanceMask = maintenanceMask & ~transmissionFaultMask;
sheddingHoursPerDay    = sum(sheddingMask, 2);
maintenanceHoursPerDay = sum(effectiveMaintenanceMask, 2);
faultHoursPerDay       = sum(transmissionFaultMask, 2);
totalOutageHoursPerDay = sum(sheddingMask | effectiveMaintenanceMask | ...
                              transmissionFaultMask, 2);

statistics.daily.shedding    = sheddingHoursPerDay;
statistics.daily.maintenance = maintenanceHoursPerDay;
statistics.daily.fault       = faultHoursPerDay;
statistics.daily.total       = totalOutageHoursPerDay;

statistics.monthly.shedding    = accumarray(monthOfDay(:), sheddingHoursPerDay);
statistics.monthly.maintenance = accumarray(monthOfDay(:), maintenanceHoursPerDay);
statistics.monthly.fault       = accumarray(monthOfDay(:), faultHoursPerDay);
statistics.monthly.total       = statistics.monthly.shedding + ...
                                 statistics.monthly.maintenance + ...
                                 statistics.monthly.fault;
statistics.monthly.calendarHours  = daysInMonth(:) * 24;
statistics.monthly.unavailability = 100 * statistics.monthly.total ./ ...
                                    statistics.monthly.calendarHours;
statistics.monthly.hoursPerDay    = statistics.monthly.total ./ daysInMonth(:);
statistics.monthly.longDays       = accumarray(monthOfDay(:), ...
    double(sheddingHoursPerDay >= parameters.longSheddingDayThreshold), [12 1]);

statistics.annual.shedding       = sum(statistics.monthly.shedding);
statistics.annual.maintenance    = sum(statistics.monthly.maintenance);
statistics.annual.fault          = sum(statistics.monthly.fault);
statistics.annual.total          = sum(statistics.monthly.total);
statistics.annual.unavailability = 100 * statistics.annual.total / totalHours;
statistics.annual.sheddingDays   = sum(sheddingHoursPerDay > 0);
statistics.faultDurations        = faultDurations(:);
statistics.faultIsSevere         = faultIsSevere(:);
statistics.annual.severeEvents   = sum(faultIsSevere);
statistics.annual.suppressedDays         = numberOfSuppressedDays;
statistics.annual.suppressedSheddingHours = sheddingHoursSuppressed;
statistics.parameters            = parameters;

blockDurations = shedding_block_durations(sheddingMask);
statistics.blockDurations = blockDurations;

maximumDailyShedding = max(sheddingHoursPerDay);
countAtMaximumDaily  = sum(sheddingHoursPerDay == maximumDailyShedding);
maximumBlockDuration = max(blockDurations);
countAtMaximumBlock  = sum(blockDurations == maximumBlockDuration);
placementShortfall   = sum(requestedBudgetHours) - ...
                       sum(sheddingHoursPerDay(requestedBudgetHours > 0));
sheddingDayHours     = sheddingHoursPerDay(sheddingHoursPerDay > 0);

statistics.annual.maximumDailyShedding = maximumDailyShedding;
statistics.annual.countAtMaximumDaily  = countAtMaximumDaily;
statistics.annual.maximumBlockDuration = maximumBlockDuration;
statistics.annual.countAtMaximumBlock  = countAtMaximumBlock;
statistics.annual.placementShortfall   = placementShortfall;

% ------------------------------------------------------------------ report
monthNames = {'Jan','Feb','Mar','Apr','May','Jun', ...
              'Jul','Aug','Sep','Oct','Nov','Dec'};

if parameters.verbose
fprintf('\n  Feeder grid unavailability, synthetic year (seed %d)\n\n', ...
        parameters.randomSeed);
fprintf('  %-5s %9s %9s %9s %9s %9s %8s %9s\n', 'Month','Shed h','Maint h', ...
        'Fault h','Total h','h/day','Unavail%','Long days');
fprintf('  %s\n', repmat('-', 1, 76));
for monthIndex = 1:12
    fprintf('  %-5s %9.0f %9.0f %9.0f %9.0f %9.2f %7.1f%% %9d\n', ...
        monthNames{monthIndex}, ...
        statistics.monthly.shedding(monthIndex), ...
        statistics.monthly.maintenance(monthIndex), ...
        statistics.monthly.fault(monthIndex), ...
        statistics.monthly.total(monthIndex), ...
        statistics.monthly.hoursPerDay(monthIndex), ...
        statistics.monthly.unavailability(monthIndex), ...
        statistics.monthly.longDays(monthIndex));
end
fprintf('  %s\n', repmat('-', 1, 76));
fprintf('  %-5s %9.0f %9.0f %9.0f %9.0f %9.2f %7.1f%% %9d\n\n', 'Year', ...
    statistics.annual.shedding, statistics.annual.maintenance, ...
    statistics.annual.fault, statistics.annual.total, ...
    statistics.annual.total/numberOfDays, statistics.annual.unavailability, ...
    sum(statistics.monthly.longDays));
fprintf('  Long day = %d or more hours of deficit shedding.\n\n', ...
        parameters.longSheddingDayThreshold);

% -- how long the daily deficit shedding runs, and how often --------------
fprintf('  Daily deficit shedding duration, frequency across the year\n\n');
fprintf('  %10s %10s %12s\n', 'Hours/day', 'Days', 'Share of yr');
fprintf('  %s\n', repmat('-', 1, 34));
uniqueDurations  = unique(sheddingDayHours);
for k = 1:numel(uniqueDurations)
    countDays = sum(sheddingDayHours == uniqueDurations(k));
    fprintf('  %10.0f %10d %11.1f%%\n', uniqueDurations(k), countDays, ...
            100*countDays/numberOfDays);
end
fprintf('  %s\n', repmat('-', 1, 34));

fprintf('  Longest shedding day       : %.0f h, occurring %d time(s)\n', ...
        maximumDailyShedding, countAtMaximumDaily);
fprintf('  Longest single block       : %.0f h, occurring %d time(s)\n', ...
        maximumBlockDuration, countAtMaximumBlock);
fprintf('  Days with deficit shedding : %d of %d (%.0f%%)\n', ...
        statistics.annual.sheddingDays, numberOfDays, ...
        100*statistics.annual.sheddingDays/numberOfDays);
fprintf('  Mean on shedding days      : %.2f h\n', ...
        statistics.annual.shedding / max(statistics.annual.sheddingDays,1));

if ~isempty(faultDurations)
    ordinaryDurations = faultDurations(~faultIsSevere);
    severeDurations   = faultDurations(faultIsSevere);
    fprintf('  Transmission fault events  : %d total\n', numel(faultDurations));
    if ~isempty(ordinaryDurations)
        fprintf('    ordinary                 : %d, %.0f to %.0f h, median %.0f h\n', ...
            numel(ordinaryDurations), min(ordinaryDurations), ...
            max(ordinaryDurations), median(ordinaryDurations));
    end
    if ~parameters.includeSevereFaults
        fprintf('    severe tier              : disabled (design year)\n');
    elseif isempty(severeDurations)
        fprintf('    severe or flood-related  : none this year\n');
    else
        fprintf('    severe or flood-related  : %d, %.0f to %.0f h (%.1f to %.1f days)\n', ...
            numel(severeDurations), min(severeDurations), max(severeDurations), ...
            min(severeDurations)/24, max(severeDurations)/24);
    end
end
fprintf('  Worst day, any cause       : %.0f h\n', max(totalOutageHoursPerDay));
if numberOfSuppressedDays > 0 && parameters.verbose
    fprintf(['  Shedding suppressed on %d day(s) that saw a fault or\n' ...
             '        maintenance outage, removing %d scheduled hours.\n'], ...
             numberOfSuppressedDays, sheddingHoursSuppressed);
end
if placementShortfall > 0 && parameters.verbose
    fprintf(['  Note: %.0f budgeted shedding hours could not be placed ' ...
             'within the day\n        without violating the minimum gap.\n'], ...
             placementShortfall);
end
fprintf('\n');
end   % if parameters.verbose

% ------------------------------------------------------------- CSV export
% Three columns, one row per hour of the year.
%
%   hour           1 to 8760, chronological
%   grid_available 1 = the feeder was supplied in that hour, 0 = out
%   outage_cause   none | shedding | maintenance | fault
%
% Note the polarity of grid_available: 1 is the good state, so the column is
% the direct multiplier on grid import in the dispatch model.
%
% The cause tag is carried in the file rather than only in the outageCause
% output because ENS has to be split by cause downstream, and that split is
% what separates the reliability result (shedding-driven) from the resilience
% result (fault-driven). Exporting a bare availability column would make the
% split unreproducible from the published data.
%
% Maintenance is kept distinct from fault, not folded into it. Maintenance is
% announced in advance and a controller can pre-charge for it; faults arrive
% without warning. Collapsing the two would erase that asymmetry.
%
% All blocks are whole hours, so the file is an exact representation of
% gridAvailability and outageCause.
hourOfYear  = (1:totalHours).';
causeLabels = {'none', 'shedding', 'maintenance', 'fault'};
causeText   = causeLabels(outageCause + 1).';

statistics.causeText = causeText;

if parameters.writeCsv
    outageTable = table(hourOfYear, gridAvailability, string(causeText), ...
                        'VariableNames', {'hour','grid_available','outage_cause'});
    writetable(outageTable, parameters.outputCsvFile);
    if parameters.verbose
        fprintf('  Written %s\n', parameters.outputCsvFile);
        fprintf('    %-12s %5d h  (%.2f%%)\n', 'available', ...
                sum(gridAvailability == 1), ...
                100*sum(gridAvailability == 1)/totalHours);
        for causeIndex = 1:3
            hoursThisCause = sum(outageCause == causeIndex);
            fprintf('    %-12s %5d h  (%.2f%%)\n', causeLabels{causeIndex+1}, ...
                    hoursThisCause, 100*hoursThisCause/totalHours);
        end
        fprintf('\n');
    end
end

if ~parameters.makePlots
    return
end

% ------------------------------------------------------- figure 1: daily bar
figure('Color','w','Position',[100 100 1100 420]);
barHandle = bar(1:numberOfDays, ...
    [sheddingHoursPerDay maintenanceHoursPerDay faultHoursPerDay], ...
    1.0, 'stacked', 'EdgeColor','none');
set(barHandle(1), 'FaceColor', [0.25 0.48 0.72]);
set(barHandle(2), 'FaceColor', [0.85 0.65 0.20]);
set(barHandle(3), 'FaceColor', [0.70 0.25 0.22]);
xlim([0 numberOfDays+1]);
set(gca, 'XTick', firstDayOfMonth + daysInMonth/2, 'XTickLabel', monthNames, ...
         'TickDir','out', 'Box','off', 'FontSize', 10);
ylabel('Outage hours per day');
xlabel('Day of year');
title('Daily grid unavailability on the study feeder');
legend({'Deficit shedding','Planned maintenance','Transmission fault'}, ...
       'Location','northeast', 'Box','off');
grid on; set(gca, 'GridAlpha', 0.12, 'Layer', 'top');

% ------------------------------------- figure 2: hour-of-day x month heatmap
heatmapMatrix = zeros(hoursPerDay, 12);
for monthIndex = 1:12
    daysThisMonth = monthOfDay == monthIndex;
    heatmapMatrix(:,monthIndex) = ...
        mean(double(sheddingMask(daysThisMonth,:)), 1).' * 100;
end
figure('Color','w','Position',[100 100 620 420]);
imagesc(1:12, 0:23, heatmapMatrix);
set(gca, 'YDir','normal', 'XTick', 1:12, 'XTickLabel', monthNames, ...
         'YTick', 0:3:23, 'TickDir','out', 'FontSize', 10);
ylabel('Hour of day'); xlabel('Month');
title('Probability of deficit shedding (% of hours)');
colorbarHandle = colorbar;
colorbarHandle.Label.String = '% of hours shed';
colormap(parula);

% ------------------------------- figure 3: daily duration and fault duration
figure('Color','w','Position',[100 100 980 380]);

subplot(1,2,1);
histogram(sheddingDayHours, 'BinEdges', 0.5:1:(maximumDailyShedding+0.5), ...
          'FaceColor', [0.25 0.48 0.72], 'EdgeColor','none');
set(gca, 'TickDir','out', 'Box','off', 'FontSize', 10);
xlabel('Deficit shedding hours per day'); ylabel('Number of days');
title('Daily shedding duration');
grid on; set(gca, 'GridAlpha', 0.12, 'Layer', 'top');

subplot(1,2,2);
if ~isempty(faultDurations)
    binEdges = 0:4:(max(faultDurations) + 4);
    histogram(faultDurations(~faultIsSevere), 'BinEdges', binEdges, ...
        'FaceColor', [0.70 0.25 0.22], 'EdgeColor','none');
    hold on;
    if any(faultIsSevere)
        histogram(faultDurations(faultIsSevere), 'BinEdges', binEdges, ...
            'FaceColor', [0.30 0.16 0.30], 'EdgeColor','none');
        legend({'Ordinary','Severe or flood'}, 'Location','northeast', 'Box','off');
    end
    hold off;
end
set(gca, 'TickDir','out', 'Box','off', 'FontSize', 10);
xlabel('Transmission fault duration (h)'); ylabel('Number of events');
title('Fault duration');
grid on; set(gca, 'GridAlpha', 0.12, 'Layer', 'top');

end

% =========================================================================
function parameters = shedding_defaults()
% Every value a reviewer would question lives here, in one place, so the
% sensitivity sweep can vary it without touching the model code.

parameters.randomSeed    = 42;
parameters.outputCsvFile = 'loadshedding_schedule_1_year_with_status_flag.csv';
parameters.verbose       = true;   % set false when looping over many seeds
parameters.makePlots     = false;  % package default: no figures during data generation
parameters.writeCsv      = true;

% A day that sees a fault or a maintenance shutdown gets no deficit shedding
% at all that day, not just during the outage itself. Set false to revert to
% suppressing only the overlapping hours.
parameters.suppressSheddingOnOutageDays = true;

% -- deficit shedding -----------------------------------------------------
% Mean shedding hours per SHEDDING DAY, by month. This is conditional on the
% day having shedding at all: the realised annual mean per calendar day is
% meanSheddingHoursPerSheddingDay .* (1 - probabilityNoSheddingDay).
% Operator reports 2-3 h typical, occasionally 4-7 h when national generation
% is short. Seasonal shape follows national peak demand.
parameters.meanSheddingHoursPerSheddingDay = ...
    [1.5 2.0 2.8 3.2 3.0 2.6 2.5 2.5 2.4 2.2 1.8 1.4];

% Probability a given day sees no shedding at all (all feeders on).
parameters.probabilityNoSheddingDay = ...
    [0.30 0.22 0.12 0.10 0.12 0.15 0.15 0.15 0.18 0.20 0.25 0.32];

% Lognormal spread of the daily budget, by month. Raised in the hot and
% monsoon months so the 4-7 hour days cluster there. This widens the tail
% without moving the typical day, which is what the operator describes:
% ordinary days stay 2-3 h, but the bad days arrive in summer.
parameters.sheddingBudgetLogSigma = ...
    [0.40 0.42 0.48 0.55 0.58 0.58 0.58 0.58 0.55 0.45 0.40 0.38];

parameters.maximumDailySheddingHours = 7;
parameters.minimumBlockDuration      = 1;    % no sub-hour shedding
parameters.blockDurations            = [1 2];
parameters.blockProbabilities        = [0.88 0.12];
parameters.minimumGapHours           = 1;    % supply required between two blocks
parameters.maximumPlacementAttempts  = 60;
parameters.deficitWeightExponent     = 2.5;  % sharpens placement onto the peak
parameters.longSheddingDayThreshold  = 4;    % reporting threshold only

% Hour-of-day deficit weight. Shedding follows national demand exceeding
% generation, so it concentrates on the evening peak. Index 1 = hour 00:00.
parameters.deficitWeightDrySeason = ...
    [0.02 0.02 0.02 0.02 0.03 0.05 0.25 0.30 0.35 0.35 0.55 0.65 ...
     0.65 0.60 0.50 0.50 0.60 0.85 1.00 1.00 1.00 0.95 0.70 0.35];

% Irrigation season lifts overnight and morning national demand, so the
% deficit window widens rather than shifting.
parameters.deficitWeightIrrigationSeason = ...
    [0.30 0.30 0.30 0.30 0.30 0.35 0.45 0.50 0.50 0.45 0.55 0.65 ...
     0.65 0.60 0.50 0.50 0.60 0.85 1.00 1.00 1.00 0.95 0.70 0.45];

parameters.irrigationMonths = 1:4;

% -- planned maintenance --------------------------------------------------
parameters.maintenanceEventsPerYear = 2;
parameters.maintenanceMonths        = [2 3 4];   % spring line work
parameters.maintenanceStartHour     = 9;
parameters.maintenanceDuration      = 6;

% -- transmission faults --------------------------------------------------
% Storm, tree fall, line damage. Poisson arrivals concentrated in the
% pre-monsoon squall season and the monsoon; near zero in winter.
parameters.faultEventsPerMonth = ...
    [0.10 0.10 0.20 0.90 1.40 1.50 1.40 1.30 1.00 0.50 0.15 0.10];

% Ordinary faults. A floor of 2 h covers switching, fault location and crew
% travel; the Weibull term is the repair. Shape 1.6 and scale 5.5 give a
% median around 6.4 h, matching the reported pattern of the line being cleared
% within 6-8 h of the storm passing. The tail is unbounded, so roughly 7% of
% ordinary events still run past 12 h.
parameters.minimumFaultDuration = 2;
parameters.faultDurationShape   = 1.6;
parameters.faultDurationScale   = 5.5;

% Severe or flood-related events. Access is the constraint rather than the
% repair, so these run for days.
%
% OFF BY DEFAULT. The design year used for sizing excludes them, so the
% optimiser is not sized by a single rare draw it has no way to characterise
% from one year of data. Switch on for the multi-year reliability testing of
% the already-optimised design; see shedding_scenario below.
parameters.includeSevereFaults = false;

% Probability that a given fault escalates to the severe tier, by month: zero
% outside the storm and flood season, peaking in the late monsoon. With the
% rates above this yields roughly one severe event every one to two years, so
% about 46% of test years contain none.
parameters.severeFaultProbability = ...
    [0.00 0.00 0.00 0.02 0.04 0.08 0.10 0.12 0.10 0.04 0.00 0.00];
parameters.minimumSevereFaultDuration = 24;
parameters.severeFaultDurationShape   = 1.0;   % exponential tail
parameters.severeFaultDurationScale   = 36;    % median about 49 h, mean 60 h

% Numerical guard only, not a physical cap. Binds on about one event in ten
% thousand and exists to stop a pathological draw overrunning the year.
parameters.absoluteFaultDurationLimit = 240;
end

% =========================================================================
function parameters = shedding_scenario(scenarioName, randomSeed)
% SHEDDING_SCENARIO  Parameter presets for the design / test split.
%
%   parameters = shedding_scenario('design')
%   parameters = shedding_scenario('test',   seed)
%   parameters = shedding_scenario('stress', seed)
%
%   'design'  Severe events off. This is the single year the microgrid is
%             sized against. Excluding the rare tier keeps the sizing from
%             hinging on one unrepresentative draw.
%
%   'test'    Severe events on at their nominal rate. Run across many seeds
%             to measure how the already-fixed design performs against years
%             it was not sized for.
%
%   'stress'  A bad year: national generation shortfall worse than normal, so
%             more shedding and longer days, and severe faults three times as
%             likely. Represents conditions like the 2022 shortage combined
%             with an active storm season.

parameters = shedding_defaults();
if nargin > 1 && ~isempty(randomSeed)
    parameters.randomSeed = randomSeed;
end

switch lower(scenarioName)
    case 'design'
        parameters.includeSevereFaults = false;

    case 'test'
        parameters.includeSevereFaults = true;

    case 'stress'
        parameters.includeSevereFaults = true;
        parameters.severeFaultProbability = ...
            min(3 * parameters.severeFaultProbability, 0.5);
        parameters.faultEventsPerMonth = 1.5 * parameters.faultEventsPerMonth;
        parameters.meanSheddingHoursPerSheddingDay = ...
            1.4 * parameters.meanSheddingHoursPerSheddingDay;
        parameters.probabilityNoSheddingDay = ...
            0.5 * parameters.probabilityNoSheddingDay;
        parameters.maximumDailySheddingHours = 9;

    otherwise
        error('shedding_scenario:unknownScenario', ...
              'Scenario must be design, test or stress.');
end
end

% =========================================================================
function dayRow = place_shedding_blocks(budgetHours, deficitWeight, parameters)
% Place whole-hour shedding blocks within one day so their durations sum to
% the budget. Blocks may not touch: at least minimumGapHours of supply
% between them, so a 4 h budget becomes separate blocks rather than one run.
%
% The block sequence is composed before placement rather than drawn greedily
% during it, which keeps the realised mix of 1 h and 2 h blocks close to the
% specified probabilities.

hoursPerDay = 24;
dayRow   = false(1, hoursPerDay);
occupied = false(1, hoursPerDay);

blockQueue          = [];
remainingWholeHours = budgetHours;
attemptCount        = 0;
while remainingWholeHours > 0 && attemptCount < parameters.maximumPlacementAttempts
    attemptCount = attemptCount + 1;
    if remainingWholeHours == 1
        blockQueue(end+1) = 1; %#ok<AGROW>
        remainingWholeHours = 0;
    else
        chosenDuration = parameters.blockDurations( ...
            pick_weighted_index(parameters.blockProbabilities));
        blockQueue(end+1) = chosenDuration; %#ok<AGROW>
        remainingWholeHours = remainingWholeHours - chosenDuration;
    end
end

for blockIndex = 1:numel(blockQueue)
    blockSpanHours = blockQueue(blockIndex);

    % feasible start hours: block free, and the gap free on either side
    feasibleStart = false(1, hoursPerDay);
    for candidateStart = 1:(hoursPerDay - blockSpanHours + 1)
        windowStart = max(1, candidateStart - parameters.minimumGapHours);
        windowEnd   = min(hoursPerDay, candidateStart + blockSpanHours - 1 + ...
                                       parameters.minimumGapHours);
        if ~any(occupied(windowStart:windowEnd))
            feasibleStart(candidateStart) = true;
        end
    end
    if ~any(feasibleStart)
        break                                    % day is full, drop the rest
    end

    startWeight = zeros(1, hoursPerDay);
    for candidateStart = find(feasibleStart)
        startWeight(candidateStart) = ...
            mean(deficitWeight(candidateStart:candidateStart+blockSpanHours-1)) ...
            ^ parameters.deficitWeightExponent;
    end
    startHour = pick_weighted_index(startWeight);

    dayRow(startHour:startHour+blockSpanHours-1)   = true;
    occupied(startHour:startHour+blockSpanHours-1) = true;
end
end

% =========================================================================
function selectedIndex = pick_weighted_index(weights)
% Sample an index with probability proportional to weights. No toolbox needed.
weights = weights(:).';
weights(weights < 0) = 0;
cumulativeWeight = cumsum(weights);
if cumulativeWeight(end) <= 0
    selectedIndex = randi(numel(weights));
    return
end
selectedIndex = find(rand*cumulativeWeight(end) <= cumulativeWeight, 1, 'first');
end

% =========================================================================
function eventCount = poisson_sample(meanRate)
% Knuth's Poisson sampler. Avoids a Statistics Toolbox dependency.
if meanRate <= 0
    eventCount = 0;
    return
end
threshold  = exp(-meanRate);
eventCount = 0;
product    = 1;
while true
    product = product * rand;
    if product <= threshold
        break
    end
    eventCount = eventCount + 1;
end
end

% =========================================================================
function blockDurations = shedding_block_durations(sheddingMask)
% Length in hours of each contiguous shedding block, read chronologically.
isShedding     = reshape(sheddingMask.', [], 1);
transitions    = diff([0; double(isShedding); 0]);
blockDurations = find(transitions == -1) - find(transitions == 1);
end

% =========================================================================
% NOTES ON PARAMETER PROVENANCE
%
% meanSheddingHoursPerSheddingDay, probabilityNoSheddingDay, sheddingBudgetLogSigma
%     Operator description: 2-3 h/day typical per feeder, occasionally 4-7 h
%     when other feeders need priority, and the long days cluster in the hot
%     and monsoon months. REPLACE with fitted values if the utility's daily
%     demand/served messages can be exported in bulk; each message gives shed
%     MW and a timestamp.
%
% deficitWeightDrySeason, deficitWeightIrrigationSeason
%     Assumed. Verify against message timestamps: the hour-of-day histogram of
%     reported shedding events is a direct estimate of these vectors and would
%     move them from assumption to measurement. If fitted, set
%     deficitWeightExponent to 1, since the exponent exists only to sharpen an
%     assumed shape.
%
% faultEventsPerMonth, faultDurationScale
%     Placeholder, shaped to the reported behaviour: a 2-3 h minimum, most
%     lines cleared within 6-8 h of the storm passing, and a minority running
%     to 10-12 h or beyond. Needs operator input on events per year. Sweep the
%     rate and the scale in the sensitivity analysis until pinned down.
%
% severeFaultProbability, severeFaultDurationScale
%     The rare cyclone or flood tier, where restoration is limited by access
%     rather than repair. Least well constrained parameter in the model, and
%     it drives the resilience result almost single-handedly, so it must be
%     swept rather than reported as a point estimate. Because these events are
%     rare, a single sampled year says nothing about them: run many seeds and
%     report the distribution, and use the deterministic forced-outage
%     scenarios for the worst-case sizing check, with the genset fuel store
%     not replenished for the duration.
