function reliabilityTest = runReliabilityTest(optimizerResultsFile, outputFolder, ...
                                              numberOfTestYears, numberOfStressYears)
%RUNRELIABILITYTEST  Out-of-sample reliability and resilience test.
%
%   reliabilityTest = runReliabilityTest()
%   reliabilityTest = runReliabilityTest(optimizerResultsFile, outputFolder)
%   reliabilityTest = runReliabilityTest(optimizerResultsFile, outputFolder, ...
%                                        numberOfTestYears, numberOfStressYears)
%
%   Defaults:
%       optimizerResultsFile = './results/optimizerResults.mat'
%       outputFolder         = './results/reliabilityTest'
%       numberOfTestYears    = 200
%       numberOfStressYears  = 50
%
%   Pass any year counts you like, e.g. runReliabilityTest([],[],20,5) for a
%   fast 20/5 smoke test, or runReliabilityTest([],[],1000,200) for a larger
%   run. Every output file (CSV, MAT, figures) sizes itself from however many
%   years you asked for - nothing needs editing inside the file.
%
% WHAT THIS DOES
%   Freezes two sizings from optimizerResults.mat and scores both of them on
%   200 out-of-sample test years plus 50 stress years. Every year is drawn
%   from the SAME generative outage sampler the optimiser used
%   (sampleOutageTrace) so the test is a like-for-like extension of the
%   in-sample fit, not a different distribution.
%
%       (a) results.cells.awareAware.sizing   outage-aware microgrid
%       (b) results.cells.blindBlind.sizing   grid-only baseline (no PV/BESS/DG)
%
%   Both designs are evaluated on the SAME seed inside the SAME loop
%   iteration, so all comparisons are paired.
%
% OUTPUTS
%   outputFolder/perYearTest.csv     one row per test year, both designs
%   outputFolder/perYearStress.csv   one row per stress year, both designs
%   outputFolder/summaryMetrics.csv  aggregate paper table
%   outputFolder/reliabilityTest.mat all results, keyed by scenario and design
%   outputFolder/fig_*.png           four figures
%
% NOTHING is re-optimised. The sizings are read from disk and never modified.

if nargin < 1 || isempty(optimizerResultsFile)
    optimizerResultsFile = fullfile('.', 'results', 'optimizerResults.mat');
end
if nargin < 2 || isempty(outputFolder)
    outputFolder = fullfile('.', 'results', 'reliabilityTest');
end
if nargin < 3 || isempty(numberOfTestYears)
    numberOfTestYears = 200;
end
if nargin < 4 || isempty(numberOfStressYears)
    numberOfStressYears = 50;
end

setupPaths();
if ~exist(outputFolder, 'dir'); mkdir(outputFolder); end

%% ---------------------------------------------------------- configuration
config.numberOfTestYears   = numberOfTestYears;
config.numberOfStressYears = numberOfStressYears;
config.firstTestSeed       = 20260101;
config.firstStressSeed     = 20260501;
config.durationBinEdges    = [1 2 4 6 12 24 48 Inf];   % hours

%% ------------------------------------------------- load the frozen designs
fprintf('\n=== Loading frozen designs ===\n');

loaded = load(optimizerResultsFile);
r      = loaded.results;

designAware    = r.cells.awareAware.sizing;
designGridOnly = r.cells.blindBlind.sizing;

policyAware    = r.awarePolicy;
policyGridOnly = r.blindPolicy;

P               = r.P;
inputs          = r.inputs;
photovoltaicPerKilowatt = r.photovoltaic.generationPerInstalledKilowatt;
statistics      = r.statistics;

printDesign('Outage-aware ', designAware);
printDesign('Grid-only    ', designGridOnly);

% Sanity check the out-of-sample guarantee
assert(config.firstTestSeed   ~= P.optimisation.inSampleTraceSeed, ...
       'Test seeds overlap the in-sample optimiser seed.');
assert(config.firstStressSeed ~= P.optimisation.inSampleTraceSeed, ...
       'Stress seeds overlap the in-sample optimiser seed.');
testSeeds   = config.firstTestSeed   + (0:config.numberOfTestYears-1);
stressSeeds = config.firstStressSeed + (0:config.numberOfStressYears-1);
assert(isempty(intersect(testSeeds, stressSeeds)), ...
       'Test and stress seed ranges overlap.');

%% ---------------------------------------------- generate the outage years
fprintf('\n=== Generating out-of-sample outage years ===\n');

testYears   = generateOutageYears(statistics, testSeeds,   P, 'test');
stressYears = generateOutageYears(statistics, stressSeeds, P, 'stress');

%% ----------------------------------------------- score every year, both designs
fprintf('\n=== Scoring both designs on every year ===\n');

photovoltaicGenerationAware    = photovoltaicPerKilowatt * designAware.photovoltaicCapacityKilowatts;
photovoltaicGenerationGridOnly = photovoltaicPerKilowatt * designGridOnly.photovoltaicCapacityKilowatts;

testAware      = scoreEnsemble('test  aware',      designAware,    policyAware, ...
                               photovoltaicGenerationAware,    inputs, testYears,   P);
testGridOnly   = scoreEnsemble('test  grid-only',  designGridOnly, policyGridOnly, ...
                               photovoltaicGenerationGridOnly, inputs, testYears,   P);
stressAware    = scoreEnsemble('stress aware',     designAware,    policyAware, ...
                               photovoltaicGenerationAware,    inputs, stressYears, P);
stressGridOnly = scoreEnsemble('stress grid-only', designGridOnly, policyGridOnly, ...
                               photovoltaicGenerationGridOnly, inputs, stressYears, P);

%% ------------------------------------------------------- printed report
fprintf('\n=== Results ===\n');
printComparison(sprintf('TEST YEARS  (n=%d)',   config.numberOfTestYears),   testAware,   testGridOnly);
printComparison(sprintf('STRESS YEARS (n=%d)', config.numberOfStressYears), stressAware, stressGridOnly);

paired = pairedTests(testAware, testGridOnly);
fprintf('\n  Paired comparison across the %d test years (same seeds both designs)\n', config.numberOfTestYears);
fprintf('  %s\n', repmat('-', 1, 62));
fprintf('  %-34s %10s %14s\n', 'Metric', 'p-value', 'Aware better');
fprintf('  %-34s %10.3g %13.0f%%\n', 'Loss of load probability', ...
        paired.lossOfLoadProbability.p, 100*paired.lossOfLoadProbability.fractionAwareBetter);
fprintf('  %-34s %10.3g %13.0f%%\n', 'Critical unserved energy', ...
        paired.criticalUnservedKilowattHours.p, 100*paired.criticalUnservedKilowattHours.fractionAwareBetter);
fprintf('  %-34s %10.3g %13.0f%%\n', 'Total unserved energy', ...
        paired.totalUnservedKilowattHours.p, 100*paired.totalUnservedKilowattHours.fractionAwareBetter);

%% ------------------------------------------------------------- figures
fprintf('\n=== Figures ===\n');
figureHandles = struct();
figureHandles.distributions = plotDistributions(testAware, testGridOnly, stressAware, stressGridOnly);
figureHandles.survival      = plotSurvivalCurve(testAware, testGridOnly, testYears, ...
                                                config.durationBinEdges, inputs.criticalLoadKilowatts);
figureHandles.tradeoff      = plotCostReliability(testAware, testGridOnly, stressAware, stressGridOnly);
figureHandles.byCause       = plotUnservedByCause(testAware, testGridOnly);
saveFigures(figureHandles, outputFolder);

%% -------------------------------------------------------------- save output
fprintf('\n=== Saving ===\n');
writePerYearCsv(fullfile(outputFolder, 'perYearTest.csv'),   testSeeds,   'test',   testAware,   testGridOnly,   testYears);
writePerYearCsv(fullfile(outputFolder, 'perYearStress.csv'), stressSeeds, 'stress', stressAware, stressGridOnly, stressYears);
writeSummaryCsv(fullfile(outputFolder, 'summaryMetrics.csv'), testAware, testGridOnly, stressAware, stressGridOnly, paired);
writeDailyImportCsv(fullfile(outputFolder, 'dailyImportTest.csv'),   testSeeds,   testAware,   testGridOnly);
writeMonthlyImportCsv(fullfile(outputFolder, 'monthlyImportTest.csv'), testSeeds, testAware,   testGridOnly);

reliabilityTest.config          = config;
reliabilityTest.designAware     = designAware;
reliabilityTest.designGridOnly  = designGridOnly;
reliabilityTest.testSeeds       = testSeeds;
reliabilityTest.stressSeeds     = stressSeeds;
reliabilityTest.testAware       = testAware;
reliabilityTest.testGridOnly    = testGridOnly;
reliabilityTest.stressAware     = stressAware;
reliabilityTest.stressGridOnly  = stressGridOnly;
reliabilityTest.pairedTests     = paired;
reliabilityTest.testYearStats   = stripHourlyArrays(testYears);
reliabilityTest.stressYearStats = stripHourlyArrays(stressYears);
reliabilityTest.generatedOn     = datestr(now, 'yyyy-mm-dd HH:MM:SS');

save(fullfile(outputFolder, 'reliabilityTest.mat'), 'reliabilityTest', '-v7.3');
fprintf('  All output written to %s\n\n', outputFolder);
end


%% ========================================================================
%  OUTAGE-YEAR GENERATION
%  ========================================================================
function years = generateOutageYears(statistics, seeds, P, label)
% One 8760x1 availability mask + cause vector per seed. Uses the SAME
% generator the optimiser used, so the out-of-sample test is a like-for-like
% extension of the in-sample fit.
%
% Stress mode inflates the outage rates before sampling. It shares the
% statistics object with test mode and only tweaks the calibration factors,
% which keeps the sampling code path identical.

numberOfYears = numel(seeds);
years.label                = label;
years.seeds                = seeds(:);
years.gridAvailable        = false(P.site.hoursPerYear, numberOfYears);
years.causeCodes           = zeros(P.site.hoursPerYear, numberOfYears);
years.unavailabilityPerYear = zeros(numberOfYears, 1);
years.longestOutagePerYear  = zeros(numberOfYears, 1);
years.outageEventCount      = zeros(numberOfYears, 1);
years.eventStarts           = cell(numberOfYears, 1);
years.eventDurations        = cell(numberOfYears, 1);

statisticsForSampling = statistics;
if strcmpi(label, 'stress')
    statisticsForSampling.sheddingIntensityCalibrationFactor = ...
        1.5 * statisticsForSampling.sheddingIntensityCalibrationFactor;
    statisticsForSampling.faultIntensityCalibrationFactor = ...
        3.0 * statisticsForSampling.faultIntensityCalibrationFactor;
end

for yearIndex = 1:numberOfYears
    [gridAvailable, causeCodes] = sampleOutageTrace(statisticsForSampling, ...
                                                    seeds(yearIndex), P);
    years.gridAvailable(:, yearIndex) = logical(gridAvailable);
    years.causeCodes(:, yearIndex)    = causeCodes;

    outageMask = gridAvailable == 0;
    events     = outageEvents(outageMask);

    years.unavailabilityPerYear(yearIndex) = 100 * sum(outageMask) / P.site.hoursPerYear;
    years.longestOutagePerYear(yearIndex)  = max([0; events.durations(:)]);
    years.outageEventCount(yearIndex)      = numel(events.durations);
    years.eventStarts{yearIndex}           = events.starts;
    years.eventDurations{yearIndex}        = events.durations;
end

fprintf('  %-8s : %3d years | unavailability %.2f%% median, %.2f%% p95 | longest %d h max\n', ...
        label, numberOfYears, ...
        median(years.unavailabilityPerYear), ...
        prctileSimple(years.unavailabilityPerYear, 95), ...
        max(years.longestOutagePerYear));
end

% -------------------------------------------------------------------------
function scored = scoreEnsemble(label, sizing, policy, photovoltaicGeneration, inputs, years, P)
% Run one fixed sizing across every year, calling the same dispatch and
% economics functions the optimiser used.

numberOfYears = size(years.gridAvailable, 2);

scored.label                          = label;
scored.lossOfLoadProbability          = zeros(numberOfYears, 1);
scored.criticalUnservedKilowattHours  = zeros(numberOfYears, 1);
scored.totalUnservedKilowattHours     = zeros(numberOfYears, 1);
scored.netPresentCostUsd              = zeros(numberOfYears, 1);
scored.levelisedCostUsdPerKilowattHour = zeros(numberOfYears, 1);
scored.fuelLitres                     = zeros(numberOfYears, 1);
scored.generatorHours                 = zeros(numberOfYears, 1);
scored.carbonDioxideTonnes            = zeros(numberOfYears, 1);
scored.renewableFraction              = zeros(numberOfYears, 1);
scored.gridImportKilowattHours        = zeros(numberOfYears, 1);
scored.gridExportKilowattHours        = zeros(numberOfYears, 1);
scored.unservedByCauseKilowattHours   = zeros(numberOfYears, 4);
scored.hourlyUnservedCritical         = cell(numberOfYears, 1);
scored.equivalentFullCyclesPerYear    = zeros(numberOfYears, 1);
scored.islandedHours                  = zeros(numberOfYears, 1);
scored.monthlyPeakImportKilowatts     = zeros(numberOfYears, 12);
scored.dailyGridImportKilowattHours   = zeros(numberOfYears, 365);
scored.monthlyGridImportKilowattHours = zeros(numberOfYears, 12);

progressStep = max(1, floor(numberOfYears/10));

for yearIndex = 1:numberOfYears
    gridAvailable = years.gridAvailable(:, yearIndex);
    causeCodes    = years.causeCodes(:, yearIndex);

    reserveStateOfCharge = policy.buildProfile( ...
        sizing.batteryEnergyCapacityKilowattHours, causeCodes);

    dispatchResult = dispatchSimulator(photovoltaicGeneration, inputs, ...
        gridAvailable, causeCodes, reserveStateOfCharge, sizing, P, true);

    economics = economicsModel(sizing, dispatchResult, P);

    scored.lossOfLoadProbability(yearIndex)         = dispatchResult.lossOfLoadProbabilityCritical;
    scored.criticalUnservedKilowattHours(yearIndex) = dispatchResult.unservedCriticalKilowattHours;
    scored.totalUnservedKilowattHours(yearIndex)    = dispatchResult.unservedCriticalKilowattHours + ...
                                                       dispatchResult.unservedNonCriticalKilowattHours;
    scored.netPresentCostUsd(yearIndex)             = economics.netPresentCostUsd;
    scored.levelisedCostUsdPerKilowattHour(yearIndex) = economics.levelisedCostUsdPerKilowattHour;
    scored.fuelLitres(yearIndex)                    = dispatchResult.fuelConsumedLitres;
    scored.generatorHours(yearIndex)                = dispatchResult.generatorRunningHours;
    scored.carbonDioxideTonnes(yearIndex)           = economics.carbonDioxideTonnesPerYear;
    scored.renewableFraction(yearIndex)             = dispatchResult.renewableFraction;
    scored.gridImportKilowattHours(yearIndex)       = dispatchResult.gridImportKilowattHours;
    scored.gridExportKilowattHours(yearIndex)       = dispatchResult.gridExportKilowattHours;

    causeVector = dispatchResult.unservedCriticalByCauseKilowattHours(:).';
    scored.unservedByCauseKilowattHours(yearIndex, 1:numel(causeVector)) = causeVector;

    scored.hourlyUnservedCritical{yearIndex} = dispatchResult.hourly.unservedCritical;

    scored.equivalentFullCyclesPerYear(yearIndex) = dispatchResult.equivalentFullCyclesPerYear;
    scored.islandedHours(yearIndex)               = dispatchResult.islandedHours;
    scored.monthlyPeakImportKilowatts(yearIndex,:) = dispatchResult.monthlyPeakImportKilowatts(:).';

    dailyImport   = dailyTotalsFromHourly(dispatchResult.hourly.gridImport);
    monthlyImport = monthlyTotalsFromDaily(dailyImport);
    scored.dailyGridImportKilowattHours(yearIndex,:)   = dailyImport(:).';
    scored.monthlyGridImportKilowattHours(yearIndex,:) = monthlyImport(:).';

    if mod(yearIndex, progressStep) == 0 || yearIndex == numberOfYears
        fprintf('  %-18s %3d/%3d\n', label, yearIndex, numberOfYears);
    end
end
end


%% ========================================================================
%  TIME AGGREGATION  (8760 hours = 365 days, non-leap calendar assumed
%  throughout the codebase - matches sampleOutageTrace / outageModel)
%  ========================================================================
function dailyTotals = dailyTotalsFromHourly(hourlySeries)
dailyTotals = sum(reshape(hourlySeries(1:8760), 24, 365), 1)';
end

function monthlyTotals = monthlyTotalsFromDaily(dailyTotals)
daysPerMonth  = [31 28 31 30 31 30 31 31 30 31 30 31];
monthlyTotals = zeros(12, 1);
dayIndex = 1;
for monthIndex = 1:12
    lastDay = dayIndex + daysPerMonth(monthIndex) - 1;
    monthlyTotals(monthIndex) = sum(dailyTotals(dayIndex:lastDay));
    dayIndex = lastDay + 1;
end
end


%% ========================================================================
%  STATISTICS
%  ========================================================================
function events = outageEvents(outageMask)
transitions = diff([0; double(outageMask(:)); 0]);
startIndex  = find(transitions ==  1);
endIndex    = find(transitions == -1) - 1;
events.starts    = startIndex;
events.durations = endIndex - startIndex + 1;
end

% -------------------------------------------------------------------------
function paired = pairedTests(aware, gridOnly)
paired.lossOfLoadProbability         = onePairedTest(aware.lossOfLoadProbability,        gridOnly.lossOfLoadProbability);
paired.criticalUnservedKilowattHours = onePairedTest(aware.criticalUnservedKilowattHours,gridOnly.criticalUnservedKilowattHours);
paired.totalUnservedKilowattHours    = onePairedTest(aware.totalUnservedKilowattHours,   gridOnly.totalUnservedKilowattHours);
end

function result = onePairedTest(awareValues, gridValues)
difference = gridValues(:) - awareValues(:);   % positive = aware better
result.medianAware         = median(awareValues);
result.medianGridOnly      = median(gridValues);
result.medianDifference    = median(difference);
result.fractionAwareBetter = mean(difference > 0);

if exist('signrank', 'file') == 2
    result.p    = signrank(awareValues(:), gridValues(:));
    result.test = 'Wilcoxon signed-rank';
else
    nPositive = sum(difference > 0);
    nNonZero  = sum(difference ~= 0);
    if nNonZero == 0
        result.p = 1;
    else
        result.p = 2 * min(binocdfSimple(nPositive, nNonZero, 0.5), ...
                           1 - binocdfSimple(nPositive-1, nNonZero, 0.5));
        result.p = min(result.p, 1);
    end
    result.test = 'paired sign test (no Statistics Toolbox)';
end
end

function p = binocdfSimple(k, n, prob)
% Normal approximation with continuity correction. Avoids nchoosek, which
% loses precision (and prints a warning) once n gets into the hundreds -
% exactly the range these seed counts land in. Accurate to a few parts in
% 1e4 for n > ~30, which is more than enough for a p-value used as a
% direction/significance check rather than an exact figure.
if k < 0
    p = 0;
    return
end
k = min(k, n);

mu    = n * prob;
sigma = sqrt(n * prob * (1-prob));

if sigma == 0
    p = double(k >= mu);
    return
end

z = (k + 0.5 - mu) / sigma;   % continuity correction
p = 0.5 * (1 + erf(z / sqrt(2)));
p = min(max(p, 0), 1);
end

% -------------------------------------------------------------------------
function value = prctileSimple(data, percentile)
sortedData = sort(data(:));
n = numel(sortedData);
if n == 1; value = sortedData; return; end
position   = 1 + (percentile/100)*(n-1);
lowerIndex = floor(position);
upperIndex = ceil(position);
weight     = position - lowerIndex;
value      = (1-weight)*sortedData(lowerIndex) + weight*sortedData(upperIndex);
end

% -------------------------------------------------------------------------
function printDesign(label, sizing)
fprintf('  %s: PV %.0f kW | BESS %.0f kWh | DG %.0f kW | INV %.0f kW\n', ...
        label, sizing.photovoltaicCapacityKilowatts, ...
        sizing.batteryEnergyCapacityKilowattHours, ...
        sizing.generatorRatingKilowatts, ...
        sizing.inverterRatingKilowatts);
end

% -------------------------------------------------------------------------
function printComparison(header, aware, gridOnly)
fprintf('\n  %s\n', header);
fprintf('  %s\n', repmat('=', 1, 78));
fprintf('  %-34s %14s %14s %12s\n', 'Metric', 'Outage-aware', 'Grid-only', 'Change');
fprintf('  %s\n', repmat('-', 1, 78));

row('LOLP mean',                aware.lossOfLoadProbability,          gridOnly.lossOfLoadProbability,          'mean',   '%14.4f', true);
row('LOLP P95',                 aware.lossOfLoadProbability,          gridOnly.lossOfLoadProbability,          'p95',    '%14.4f', true);
row('LOLP worst',               aware.lossOfLoadProbability,          gridOnly.lossOfLoadProbability,          'max',    '%14.4f', true);
fprintf('  %s\n', repmat('-', 1, 78));
row('Critical ENS mean, kWh',   aware.criticalUnservedKilowattHours,  gridOnly.criticalUnservedKilowattHours,  'mean',   '%14.0f', true);
row('Critical ENS P95, kWh',    aware.criticalUnservedKilowattHours,  gridOnly.criticalUnservedKilowattHours,  'p95',    '%14.0f', true);
row('Critical ENS worst, kWh',  aware.criticalUnservedKilowattHours,  gridOnly.criticalUnservedKilowattHours,  'max',    '%14.0f', true);
fprintf('  %s\n', repmat('-', 1, 78));
row('Total ENS mean, kWh',      aware.totalUnservedKilowattHours,     gridOnly.totalUnservedKilowattHours,     'mean',   '%14.0f', true);
row('Total ENS P95, kWh',       aware.totalUnservedKilowattHours,     gridOnly.totalUnservedKilowattHours,     'p95',    '%14.0f', true);
fprintf('  %s\n', repmat('-', 1, 78));
row('NPC mean, USD',            aware.netPresentCostUsd,              gridOnly.netPresentCostUsd,              'mean',   '%14.0f', false);
row('LCOE mean, USD/kWh',       aware.levelisedCostUsdPerKilowattHour,gridOnly.levelisedCostUsdPerKilowattHour,'mean',   '%14.4f', false);
row('Fuel mean, L/yr',          aware.fuelLitres,                     gridOnly.fuelLitres,                     'mean',   '%14.0f', false);
row('CO2 mean, t/yr',           aware.carbonDioxideTonnes,            gridOnly.carbonDioxideTonnes,            'mean',   '%14.1f', false);
fprintf('  %s\n', repmat('-', 1, 78));
row('Battery cycles mean, /yr', aware.equivalentFullCyclesPerYear,    gridOnly.equivalentFullCyclesPerYear,    'mean',   '%14.1f', false);
row('Islanded hours mean',      aware.islandedHours,                  gridOnly.islandedHours,                  'mean',   '%14.1f', false);
row('Peak monthly import, kW',  max(aware.monthlyPeakImportKilowatts,[],2), max(gridOnly.monthlyPeakImportKilowatts,[],2), 'mean', '%14.0f', false);
fprintf('  %s\n', repmat('=', 1, 78));

    function row(label, awareData, gridData, statistic, numberFormat, lowerIsBetter)
        a = applyStatistic(awareData, statistic);
        g = applyStatistic(gridData,  statistic);
        if abs(g) < eps
            changeText = '     n/a';
        else
            changeText = sprintf('%+11.1f%%', 100*(a-g)/abs(g));
        end
        marker = '';
        if lowerIsBetter && a < g; marker = ' *'; end
        fprintf(['  %-34s ' numberFormat ' ' numberFormat ' %12s%s\n'], ...
                label, a, g, changeText, marker);
    end
end

function value = applyStatistic(data, statistic)
switch statistic
    case 'mean',   value = mean(data);
    case 'median', value = median(data);
    case 'p95',    value = prctileSimple(data, 95);
    case 'max',    value = max(data);
end
end


%% ========================================================================
%  FIGURES
%  ========================================================================
function fh = plotDistributions(testAware, testGridOnly, stressAware, stressGridOnly)
awareColour = [0.20 0.45 0.70];
gridColour  = [0.75 0.30 0.25];

fh = figure('Color','w','Position',[80 80 1180 720], 'Name','Reliability distributions');

panels = { ...
    'Loss of load probability',            testAware.lossOfLoadProbability,          testGridOnly.lossOfLoadProbability,          stressAware.lossOfLoadProbability,          stressGridOnly.lossOfLoadProbability; ...
    'Critical unserved energy (kWh/yr)',   testAware.criticalUnservedKilowattHours,  testGridOnly.criticalUnservedKilowattHours,  stressAware.criticalUnservedKilowattHours,  stressGridOnly.criticalUnservedKilowattHours; ...
    'Total unserved energy (kWh/yr)',      testAware.totalUnservedKilowattHours,     testGridOnly.totalUnservedKilowattHours,     stressAware.totalUnservedKilowattHours,     stressGridOnly.totalUnservedKilowattHours };

for panelIndex = 1:3
    subplot(2, 3, panelIndex);
    hold on;
    histogram(panels{panelIndex,2}, 25, 'FaceColor', awareColour, 'EdgeColor','none', 'FaceAlpha', 0.72);
    histogram(panels{panelIndex,3}, 25, 'FaceColor', gridColour,  'EdgeColor','none', 'FaceAlpha', 0.62);
    hold off;
    set(gca,'TickDir','out','Box','off','FontSize',9);
    xlabel(panels{panelIndex,1}); ylabel('Test years');
    title(sprintf('Test years (n=%d)', numel(panels{panelIndex,2})), 'FontWeight','normal');
    if panelIndex == 1
        legend({'Outage-aware','Grid-only'}, 'Location','best', 'Box','off');
    end
    grid on; set(gca,'GridAlpha',0.12,'Layer','top');

    subplot(2, 3, panelIndex + 3);
    grouped = [panels{panelIndex,2}(:); panels{panelIndex,3}(:); ...
               panels{panelIndex,4}(:); panels{panelIndex,5}(:)];
    labels  = [repmat({'Aware/test'},   numel(panels{panelIndex,2}), 1); ...
               repmat({'Grid/test'},    numel(panels{panelIndex,3}), 1); ...
               repmat({'Aware/stress'}, numel(panels{panelIndex,4}), 1); ...
               repmat({'Grid/stress'},  numel(panels{panelIndex,5}), 1)];
    simpleBoxplot(grouped, labels, [awareColour; gridColour; awareColour*0.7; gridColour*0.7]);
    set(gca,'TickDir','out','Box','off','FontSize',9);
    ylabel(panels{panelIndex,1});
    title('Test vs stress', 'FontWeight','normal');
    grid on; set(gca,'GridAlpha',0.12,'Layer','top');
end

sgtitle('Outage-aware design vs grid-only baseline, out-of-sample', 'FontSize', 12);
end

% -------------------------------------------------------------------------
function fh = plotSurvivalCurve(testAware, testGridOnly, testYears, binEdges, criticalLoad)
fh = figure('Color','w','Position',[100 100 900 400], 'Name','Resilience curve');

[awareSurvival, awareCounts, binLabels] = survivalByDuration(testAware,    testYears, binEdges, criticalLoad);
[gridSurvival,  ~,           ~]         = survivalByDuration(testGridOnly, testYears, binEdges, criticalLoad);

subplot(1,2,1);
plot(1:numel(awareSurvival), 100*awareSurvival, '-o', 'Color',[0.20 0.45 0.70], 'LineWidth', 1.8, 'MarkerFaceColor','w');
hold on;
plot(1:numel(gridSurvival),  100*gridSurvival,  '-s', 'Color',[0.75 0.30 0.25], 'LineWidth', 1.8, 'MarkerFaceColor','w');
hold off;
set(gca,'XTick',1:numel(binLabels),'XTickLabel',binLabels,'TickDir','out','Box','off','FontSize',10);
ylim([0 105]);
xlabel('Outage duration'); ylabel('Critical load served (%)');
title('Critical-load survival vs outage duration','FontWeight','normal');
legend({'Outage-aware','Grid-only'},'Location','southwest','Box','off');
grid on; set(gca,'GridAlpha',0.12,'Layer','top');

subplot(1,2,2);
bar(1:numel(awareCounts), awareCounts, 'FaceColor',[0.55 0.55 0.58], 'EdgeColor','none');
set(gca,'XTick',1:numel(binLabels),'XTickLabel',binLabels,'TickDir','out','Box','off','FontSize',10);
xlabel('Outage duration'); ylabel('Number of events');
title('Events per duration bin (all test years)','FontWeight','normal');
grid on; set(gca,'GridAlpha',0.12,'Layer','top');
end

function [survivalFraction, eventCounts, binLabels] = survivalByDuration(scored, years, binEdges, criticalLoad)
criticalLoad     = criticalLoad(:);
numberOfBins     = numel(binEdges) - 1;
servedEnergy     = zeros(numberOfBins, 1);
requiredEnergy   = zeros(numberOfBins, 1);
eventCounts      = zeros(numberOfBins, 1);

for yearIndex = 1:size(years.gridAvailable, 2)
    hourlyUnserved = scored.hourlyUnservedCritical{yearIndex};
    if isempty(hourlyUnserved); continue; end
    starts    = years.eventStarts{yearIndex};
    durations = years.eventDurations{yearIndex};

    for eventIndex = 1:numel(durations)
        firstHour = starts(eventIndex);
        lastHour  = firstHour + durations(eventIndex) - 1;
        binIndex  = find(durations(eventIndex) >= binEdges(1:end-1) & ...
                         durations(eventIndex) <  binEdges(2:end), 1);
        if isempty(binIndex); continue; end

        unservedDuringEvent = sum(hourlyUnserved(firstHour:lastHour));
        criticalDuringEvent = sum(criticalLoad(firstHour:lastHour));

        servedEnergy(binIndex)   = servedEnergy(binIndex) + (criticalDuringEvent - unservedDuringEvent);
        requiredEnergy(binIndex) = requiredEnergy(binIndex) + criticalDuringEvent;
        eventCounts(binIndex)    = eventCounts(binIndex) + 1;
    end
end

survivalFraction = servedEnergy ./ max(requiredEnergy, eps);
survivalFraction(requiredEnergy == 0) = NaN;

binLabels = cell(numberOfBins, 1);
for binIndex = 1:numberOfBins
    if isinf(binEdges(binIndex+1))
        binLabels{binIndex} = sprintf('%d h+', binEdges(binIndex));
    else
        binLabels{binIndex} = sprintf('%d-%d h', binEdges(binIndex), binEdges(binIndex+1)-1);
    end
end
end

% -------------------------------------------------------------------------
function fh = plotCostReliability(testAware, testGridOnly, stressAware, stressGridOnly)
fh = figure('Color','w','Position',[120 120 1000 420], 'Name','Cost vs reliability');

subplot(1,2,1);
hold on;
scatter(testGridOnly.lossOfLoadProbability, testGridOnly.netPresentCostUsd/1e6, 22, [0.75 0.30 0.25], 'filled', 'MarkerFaceAlpha', 0.45);
scatter(testAware.lossOfLoadProbability,    testAware.netPresentCostUsd/1e6,    22, [0.20 0.45 0.70], 'filled', 'MarkerFaceAlpha', 0.45);
plot(mean(testGridOnly.lossOfLoadProbability), mean(testGridOnly.netPresentCostUsd)/1e6, 'p', 'MarkerSize', 16, 'MarkerFaceColor',[0.75 0.30 0.25], 'MarkerEdgeColor','k');
plot(mean(testAware.lossOfLoadProbability),    mean(testAware.netPresentCostUsd)/1e6,    'p', 'MarkerSize', 16, 'MarkerFaceColor',[0.20 0.45 0.70], 'MarkerEdgeColor','k');
hold off;
set(gca,'TickDir','out','Box','off','FontSize',10);
xlabel('Loss of load probability'); ylabel('Net present cost (million USD)');
title('Test years','FontWeight','normal');
legend({'Grid-only','Outage-aware','Grid-only mean','Aware mean'},'Location','best','Box','off');
grid on; set(gca,'GridAlpha',0.12,'Layer','top');

subplot(1,2,2);
hold on;
scatter(stressGridOnly.lossOfLoadProbability, stressGridOnly.levelisedCostUsdPerKilowattHour, 26, [0.75 0.30 0.25], 'filled', 'MarkerFaceAlpha', 0.5);
scatter(stressAware.lossOfLoadProbability,    stressAware.levelisedCostUsdPerKilowattHour,    26, [0.20 0.45 0.70], 'filled', 'MarkerFaceAlpha', 0.5);
hold off;
set(gca,'TickDir','out','Box','off','FontSize',10);
xlabel('Loss of load probability'); ylabel('Levelised cost (USD/kWh)');
title('Stress years','FontWeight','normal');
grid on; set(gca,'GridAlpha',0.12,'Layer','top');
end

% -------------------------------------------------------------------------
function fh = plotUnservedByCause(testAware, testGridOnly)
causeNames = {'None','Shedding','Fault','Maintenance'};

awareMeans = mean(testAware.unservedByCauseKilowattHours,    1);
gridMeans  = mean(testGridOnly.unservedByCauseKilowattHours, 1);

fh = figure('Color','w','Position',[140 140 900 400], 'Name','Unserved by cause');

subplot(1,2,1);
barHandle = bar([awareMeans; gridMeans]', 'EdgeColor','none');
barHandle(1).FaceColor = [0.20 0.45 0.70];
barHandle(2).FaceColor = [0.75 0.30 0.25];
set(gca,'XTickLabel',causeNames,'TickDir','out','Box','off','FontSize',10);
ylabel('Mean unserved energy (kWh/yr)');
title('By outage cause, test years','FontWeight','normal');
legend({'Outage-aware','Grid-only'},'Location','best','Box','off');
grid on; set(gca,'GridAlpha',0.12,'Layer','top');

subplot(1,2,2);
totalAware = sum(awareMeans);
totalGrid  = sum(gridMeans);
if totalAware > 0 && totalGrid > 0
    barHandle2 = bar([100*awareMeans/totalAware; 100*gridMeans/totalGrid]', 'EdgeColor','none');
    barHandle2(1).FaceColor = [0.20 0.45 0.70];
    barHandle2(2).FaceColor = [0.75 0.30 0.25];
end
set(gca,'XTickLabel',causeNames,'TickDir','out','Box','off','FontSize',10);
ylabel('Share of unserved energy (%)');
title('Composition','FontWeight','normal');
grid on; set(gca,'GridAlpha',0.12,'Layer','top');
end

% -------------------------------------------------------------------------
function simpleBoxplot(values, groupLabels, colours)
uniqueLabels = unique(groupLabels, 'stable');
hold on;
for groupIndex = 1:numel(uniqueLabels)
    data = values(strcmp(groupLabels, uniqueLabels{groupIndex}));
    if isempty(data); continue; end

    q1 = prctileSimple(data, 25);
    q2 = prctileSimple(data, 50);
    q3 = prctileSimple(data, 75);
    iqr = q3 - q1;
    lowerWhisker = min(data(data >= q1 - 1.5*iqr));
    upperWhisker = max(data(data <= q3 + 1.5*iqr));
    if isempty(lowerWhisker); lowerWhisker = min(data); end
    if isempty(upperWhisker); upperWhisker = max(data); end

    colour = colours(min(groupIndex, size(colours,1)), :);
    width  = 0.28;

    fill([groupIndex-width groupIndex+width groupIndex+width groupIndex-width], ...
         [q1 q1 q3 q3], colour, 'FaceAlpha', 0.55, 'EdgeColor', colour*0.6);
    plot([groupIndex-width groupIndex+width], [q2 q2], 'k-', 'LineWidth', 1.6);
    plot([groupIndex groupIndex], [lowerWhisker q1], 'k-');
    plot([groupIndex groupIndex], [q3 upperWhisker], 'k-');
    plot([groupIndex-width/2 groupIndex+width/2], [lowerWhisker lowerWhisker], 'k-');
    plot([groupIndex-width/2 groupIndex+width/2], [upperWhisker upperWhisker], 'k-');

    outliers = data(data < lowerWhisker | data > upperWhisker);
    if ~isempty(outliers)
        plot(repmat(groupIndex, numel(outliers), 1), outliers, '.', 'Color', colour*0.7, 'MarkerSize', 6);
    end
end
hold off;
xlim([0.4 numel(uniqueLabels)+0.6]);
set(gca, 'XTick', 1:numel(uniqueLabels), 'XTickLabel', uniqueLabels, 'XTickLabelRotation', 20);
end

% -------------------------------------------------------------------------
function saveFigures(figureHandles, outputFolder)
names = fieldnames(figureHandles);
for nameIndex = 1:numel(names)
    fh = figureHandles.(names{nameIndex});
    if isempty(fh) || ~ishandle(fh); continue; end
    fileName = fullfile(outputFolder, sprintf('fig_%s.png', names{nameIndex}));
    try
        exportgraphics(fh, fileName, 'Resolution', 200);
    catch
        print(fh, fileName, '-dpng', '-r200');
    end
    fprintf('  Saved: %s\n', fileName);
end
end


%% ========================================================================
%  OUTPUT FILES
%  ========================================================================
function writePerYearCsv(fileName, seeds, scenarioName, aware, gridOnly, years)
numberOfYears = numel(seeds);

header = {'yearIndex','seed','scenario','unavailabilityPercent', ...
          'longestOutageHours','outageEventCount', ...
          'awareLossOfLoadProbability','gridLossOfLoadProbability', ...
          'awareCriticalUnservedKwh','gridCriticalUnservedKwh', ...
          'awareTotalUnservedKwh','gridTotalUnservedKwh', ...
          'awareNetPresentCostUsd','gridNetPresentCostUsd', ...
          'awareLevelisedCostUsdPerKwh','gridLevelisedCostUsdPerKwh', ...
          'awareFuelLitres', ...
          'awareBatteryCyclesPerYear','gridBatteryCyclesPerYear', ...
          'awareIslandedHours','gridIslandedHours', ...
          'awarePeakMonthlyImportKw','gridPeakMonthlyImportKw'};

% Sized from numel(header), not a hardcoded number - add/remove columns above
% and this line never needs to change, regardless of how many years there are.
table = cell(numberOfYears + 1, numel(header));
table(1,:) = header;

for yearIndex = 1:numberOfYears
    row = {yearIndex, seeds(yearIndex), scenarioName, ...
        years.unavailabilityPerYear(yearIndex), ...
        years.longestOutagePerYear(yearIndex), ...
        years.outageEventCount(yearIndex), ...
        aware.lossOfLoadProbability(yearIndex),         gridOnly.lossOfLoadProbability(yearIndex), ...
        aware.criticalUnservedKilowattHours(yearIndex), gridOnly.criticalUnservedKilowattHours(yearIndex), ...
        aware.totalUnservedKilowattHours(yearIndex),    gridOnly.totalUnservedKilowattHours(yearIndex), ...
        aware.netPresentCostUsd(yearIndex),             gridOnly.netPresentCostUsd(yearIndex), ...
        aware.levelisedCostUsdPerKilowattHour(yearIndex), gridOnly.levelisedCostUsdPerKilowattHour(yearIndex), ...
        aware.fuelLitres(yearIndex), ...
        aware.equivalentFullCyclesPerYear(yearIndex), gridOnly.equivalentFullCyclesPerYear(yearIndex), ...
        aware.islandedHours(yearIndex),               gridOnly.islandedHours(yearIndex), ...
        max(aware.monthlyPeakImportKilowatts(yearIndex,:)), max(gridOnly.monthlyPeakImportKilowatts(yearIndex,:))};

    assert(numel(row) == numel(header), ...
        'writePerYearCsv: row has %d values but header has %d columns - fix the mismatch before writing.', ...
        numel(row), numel(header));

    table(yearIndex+1,:) = row;
end
writeCellCsv(fileName, table);
fprintf('  Saved: %s (%d years)\n', fileName, numberOfYears);
end

% -------------------------------------------------------------------------
function writeSummaryCsv(fileName, testAware, testGridOnly, stressAware, stressGridOnly, paired)
rows = {};
rows(end+1,:) = {'metric','ensemble','statistic','outageAware','gridOnly','pValue'};

rows = addBlock(rows, 'lossOfLoadProbability',      'test',   testAware.lossOfLoadProbability,         testGridOnly.lossOfLoadProbability,         paired.lossOfLoadProbability.p);
rows = addBlock(rows, 'criticalUnservedKwh',        'test',   testAware.criticalUnservedKilowattHours, testGridOnly.criticalUnservedKilowattHours, paired.criticalUnservedKilowattHours.p);
rows = addBlock(rows, 'totalUnservedKwh',           'test',   testAware.totalUnservedKilowattHours,    testGridOnly.totalUnservedKilowattHours,    paired.totalUnservedKilowattHours.p);
rows = addBlock(rows, 'netPresentCostUsd',          'test',   testAware.netPresentCostUsd,             testGridOnly.netPresentCostUsd,             NaN);
rows = addBlock(rows, 'levelisedCostUsdPerKwh',     'test',   testAware.levelisedCostUsdPerKilowattHour, testGridOnly.levelisedCostUsdPerKilowattHour, NaN);
rows = addBlock(rows, 'lossOfLoadProbability',      'stress', stressAware.lossOfLoadProbability,         stressGridOnly.lossOfLoadProbability,         NaN);
rows = addBlock(rows, 'criticalUnservedKwh',        'stress', stressAware.criticalUnservedKilowattHours, stressGridOnly.criticalUnservedKilowattHours, NaN);
rows = addBlock(rows, 'totalUnservedKwh',           'stress', stressAware.totalUnservedKilowattHours,    stressGridOnly.totalUnservedKilowattHours,    NaN);
rows = addBlock(rows, 'netPresentCostUsd',          'stress', stressAware.netPresentCostUsd,             stressGridOnly.netPresentCostUsd,             NaN);
rows = addBlock(rows, 'levelisedCostUsdPerKwh',     'stress', stressAware.levelisedCostUsdPerKilowattHour, stressGridOnly.levelisedCostUsdPerKilowattHour, NaN);

writeCellCsv(fileName, rows);
fprintf('  Saved: %s\n', fileName);
end

function rowsOut = addBlock(rowsIn, metricName, ensembleName, awareData, gridData, pValue)
rowsOut = rowsIn;
statistics = {'mean','median','p95','max'};
for statIndex = 1:numel(statistics)
    switch statistics{statIndex}
        case 'mean',   a = mean(awareData);          g = mean(gridData);
        case 'median', a = median(awareData);        g = median(gridData);
        case 'p95',    a = prctileSimple(awareData,95); g = prctileSimple(gridData,95);
        case 'max',    a = max(awareData);           g = max(gridData);
    end
    if strcmp(statistics{statIndex},'mean')
        pReported = pValue;
    else
        pReported = NaN;
    end
    rowsOut(end+1,:) = {metricName, ensembleName, statistics{statIndex}, a, g, pReported};
end
end

% -------------------------------------------------------------------------
function writeDailyImportCsv(fileName, seeds, aware, gridOnly)
% Mean daily grid import (kWh), averaged across all years in the ensemble,
% one row per calendar day (1-365). Per-year daily series across 200 years
% would be 200x365 columns - not useful to eyeball - so this reports the
% ensemble-mean daily profile instead. Full per-year daily data is still in
% reliabilityTest.mat (scored.dailyGridImportKilowattHours) if needed.
meanAwareDaily = mean(aware.dailyGridImportKilowattHours, 1);
meanGridDaily  = mean(gridOnly.dailyGridImportKilowattHours, 1);

table = cell(366, 3);
table(1,:) = {'dayOfYear','awareMeanImportKwh','gridMeanImportKwh'};
for dayIndex = 1:365
    table(dayIndex+1,:) = {dayIndex, meanAwareDaily(dayIndex), meanGridDaily(dayIndex)};
end
writeCellCsv(fileName, table);
fprintf('  Saved: %s\n', fileName);
end

% -------------------------------------------------------------------------
function writeMonthlyImportCsv(fileName, seeds, aware, gridOnly)
% One row per year, one column per month, both designs. Small enough to
% keep every year rather than just the ensemble mean.
monthNames = {'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'};
numberOfYears = numel(seeds);
table = cell(numberOfYears + 1, 2 + 24);
header = {'yearIndex','seed'};
for m = 1:12; header{end+1} = ['aware' monthNames{m} 'ImportKwh']; end
for m = 1:12; header{end+1} = ['grid'  monthNames{m} 'ImportKwh']; end
table(1,:) = header;
for yearIndex = 1:numberOfYears
    table(yearIndex+1,:) = [{yearIndex, seeds(yearIndex)}, ...
        num2cell(aware.monthlyGridImportKilowattHours(yearIndex,:)), ...
        num2cell(gridOnly.monthlyGridImportKilowattHours(yearIndex,:))];
end
writeCellCsv(fileName, table);
fprintf('  Saved: %s\n', fileName);
end

% -------------------------------------------------------------------------
function writeCellCsv(fileName, cellTable)
fileId = fopen(fileName, 'w');
if fileId == -1; error('Could not open %s for writing.', fileName); end
for rowIndex = 1:size(cellTable, 1)
    for columnIndex = 1:size(cellTable, 2)
        value = cellTable{rowIndex, columnIndex};
        if ischar(value)
            fprintf(fileId, '%s', value);
        elseif isnumeric(value) && isscalar(value) && isnan(value)
            fprintf(fileId, '');
        elseif isnumeric(value) && isscalar(value) && value == round(value) && abs(value) < 1e15
            fprintf(fileId, '%d', value);
        else
            fprintf(fileId, '%.6g', value);
        end
        if columnIndex < size(cellTable, 2); fprintf(fileId, ','); end
    end
    fprintf(fileId, '\n');
end
fclose(fileId);
end

% -------------------------------------------------------------------------
function outStruct = stripHourlyArrays(years)
% Drop the 8760xN arrays from the saved-out struct - keep only the per-year
% summary statistics. Hourly data can always be regenerated from the seeds.
outStruct = years;
if isfield(outStruct, 'gridAvailable'); outStruct = rmfield(outStruct, 'gridAvailable'); end
if isfield(outStruct, 'causeCodes');    outStruct = rmfield(outStruct, 'causeCodes');    end
end

% -------------------------------------------------------------------------
function setupPaths()
% Add microgrid_matlab/matlab folders relative to this file's location.
here = fileparts(mfilename('fullpath'));
candidates = { ...
    fullfile(here),                                          ...
    fullfile(here, 'matlab'),                                ...
    fullfile(here, '..'),                                    ...
    fullfile(here, '..', 'matlab'),                          ...
    fullfile(here, 'microgrid_matlab', 'matlab'),            ...
    fullfile(here, '..', 'microgrid_matlab', 'matlab') };
matlabRoot = '';
for candidateIndex = 1:numel(candidates)
    if exist(fullfile(candidates{candidateIndex}, 'components'), 'dir') && ...
       exist(fullfile(candidates{candidateIndex}, 'dispatch'),   'dir')
        matlabRoot = candidates{candidateIndex};
        break;
    end
end
if isempty(matlabRoot)
    error(['Could not find the microgrid_matlab/matlab folder. ' ...
           'Place runReliabilityTest.m inside it, or edit setupPaths() to point at it.']);
end
addpath(fullfile(matlabRoot, 'config'));
addpath(fullfile(matlabRoot, 'components'));
addpath(fullfile(matlabRoot, 'dispatch'));
addpath(fullfile(matlabRoot, 'optimizer'));
addpath(fullfile(matlabRoot, 'plots'));
end
