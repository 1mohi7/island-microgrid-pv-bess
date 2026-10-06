function results = runOptimizer(dataDirectory, numberOfSeeds, lossOfLoadThreshold)
%RUNOPTIMIZER  Produce the outage-BLIND and outage-AWARE designs. Main entry point.
%
%   results = runOptimizer()
%   results = runOptimizer(dataDirectory, numberOfSeeds, lossOfLoadThreshold)
%
%   Defaults: dataDirectory = './data',
%             numberOfSeeds = P.optimisation.independentRuns, threshold = 0.01
%
%   Runs the SAME Grey Wolf Optimizer twice. Only the fitness evaluator changes:
%
%     DESIGN BLIND   fitness on an all-hours-available counterfactual trace,
%                    reserve pinned at the state-of-charge minimum, loss-of-load
%                    constraint inactive. Represents conventional sizing that
%                    ignores grid unreliability.
%
%     DESIGN AWARE   fitness on the five in-sample outage traces, forward-looking
%                    reserve computed from fitted outage STATISTICS, loss-of-load
%                    constraint active. Represents outage-aware sizing and
%                    operation.
%
%   BOTH designs are then re-scored on IDENTICAL traces. Reporting the blind
%   design's cost from its own outage-free run would be meaningless: on an
%   all-available trace the feeder is billed for every kilowatt hour, whereas an
%   outage trace disconnects non-critical load for ~758 h/yr that nobody pays
%   for, so outages look like a saving. The four-cell table below crosses each
%   design's SIZING with each design's DISPATCH POLICY, which separates the
%   sizing effect from the operating effect using only two optimizer runs.
%
%   Results are saved to results/optimizerResults.mat.

if nargin < 1 || isempty(dataDirectory);       dataDirectory = fullfile('.', 'data'); end
if nargin < 3 || isempty(lossOfLoadThreshold); lossOfLoadThreshold = 0.01; end

setupPaths();
P = microgridParameters();
% AUDIT FIX (item 6): the default seed count comes from the config file.
if nargin < 2 || isempty(numberOfSeeds)
    numberOfSeeds = P.optimisation.independentRuns;
end

fprintf('\n================================================================\n');
fprintf('  MICROGRID SIZING - OUTAGE-BLIND vs OUTAGE-AWARE\n');
fprintf('================================================================\n');

% =====================================================================
% 1. Inputs, resource, outage model
% =====================================================================
fprintf('\n[1/5] Loading and validating inputs...\n');
inputs = loadFeederInputs(dataDirectory, P);
fprintf('      %d hours, peak %.0f kW, critical peak %.0f kW, load factor %.4f (derived)\n', ...
    P.site.hoursPerYear, inputs.peakLoadKilowatts, ...
    inputs.peakCriticalLoadKilowatts, inputs.loadFactor);
fprintf('      Timezone OK: irradiance peaks in hour bin %d, solar noon %.2f local.\n', ...
    inputs.timezoneCheck.peakIrradianceHourBin, ...
    inputs.timezoneCheck.trueSolarNoonLocalHours);
fprintf('      NO further shift applied - the solar file is already UTC+6.\n');

fprintf('\n[2/5] Building the photovoltaic resource profile...\n');
pv = photovoltaicModel(inputs, P);
fprintf('      GHI %.0f -> POA %.0f kWh/m2 (%+.1f%% transposition gain)\n', ...
    pv.annualGlobalHorizontalKilowattHoursPerSquareMetre, ...
    pv.annualPlaneOfArrayKilowattHoursPerSquareMetre, ...
    pv.transpositionGainFraction * 100);
fprintf('      Specific yield %.0f kWh/kWp, capacity factor %.4f\n', ...
    pv.annualYieldKilowattHoursPerInstalledKilowatt, pv.capacityFactor);

fprintf('\n[3/5] Fitting the outage model and sampling traces...\n');
statistics = outageModel(inputs, P);
fprintf('      Calibration factors: shedding x%.3f, fault x%.3f\n', ...
    statistics.sheddingIntensityCalibrationFactor, ...
    statistics.faultIntensityCalibrationFactor);

numberOfTraces = P.optimisation.numberOfInSampleTraces;
inSampleAvailable = zeros(numberOfTraces, P.site.hoursPerYear);
inSampleCauses    = zeros(numberOfTraces, P.site.hoursPerYear);
for traceIndex = 1:numberOfTraces
    [available, causes] = sampleOutageTrace(statistics, ...
        P.optimisation.inSampleTraceSeed + traceIndex - 1, P);
    inSampleAvailable(traceIndex, :) = available';
    inSampleCauses(traceIndex, :)    = causes';
end
[blankAvailable, blankCauses] = allHoursAvailableTrace(P);

% =====================================================================
% 2. Evaluators - the ONLY place the two designs differ
% =====================================================================
blindPolicy = reservePolicy('blind', statistics, inputs, P, 6);
awarePolicy = reservePolicy('aware', statistics, inputs, P, 6);

blindEvaluator = fitnessEvaluator(inputs, pv.generationPerInstalledKilowatt, ...
    blankAvailable', blankCauses', blindPolicy, lossOfLoadThreshold, P, false, true);

awareEvaluator = fitnessEvaluator(inputs, pv.generationPerInstalledKilowatt, ...
    inSampleAvailable, inSampleCauses, awarePolicy, lossOfLoadThreshold, P, true, true);

% Scoring evaluators: the common yardstick. Same traces for both designs; the
% dispatch policy is varied to separate the sizing effect from the operating one.
scoringBlindDispatch = fitnessEvaluator(inputs, pv.generationPerInstalledKilowatt, ...
    inSampleAvailable, inSampleCauses, blindPolicy, lossOfLoadThreshold, P, true, true);
scoringAwareDispatch = fitnessEvaluator(inputs, pv.generationPerInstalledKilowatt, ...
    inSampleAvailable, inSampleCauses, awarePolicy, lossOfLoadThreshold, P, true, true);

lowerBounds = [P.optimisation.photovoltaicCapacityBoundsKilowatts(1), ...
               P.optimisation.batteryEnergyCapacityBoundsKilowattHours(1), ...
               P.optimisation.generatorRatingBoundsKilowatts(1), ...
               P.optimisation.inverterRatingBoundsKilowatts(1)];
upperBounds = [P.optimisation.photovoltaicCapacityBoundsKilowatts(2), ...
               P.optimisation.batteryEnergyCapacityBoundsKilowattHours(2), ...
               P.optimisation.generatorRatingBoundsKilowatts(2), ...
               P.optimisation.inverterRatingBoundsKilowatts(2)];

% =====================================================================
% 3. Run both designs, same seeds, same optimizer
% =====================================================================
fprintf('\n[4/5] Optimising. Population %d, %d iterations, %d seeds, threshold %.3f\n', ...
    P.optimisation.populationSize, P.optimisation.maximumIterations, ...
    numberOfSeeds, lossOfLoadThreshold);

blindRuns = cell(numberOfSeeds, 1);
awareRuns = cell(numberOfSeeds, 1);
timerStart = tic;
for seedIndex = 1:numberOfSeeds
    % The evaluator comes back as the SECOND output and is kept only in the
    % local blindEvaluator/awareEvaluator variables, which are never saved.
    % blindRuns{seedIndex} (which IS saved) never touches it - see the note in
    % greyWolfOptimizer.m if this pattern is unclear.
    [blindRuns{seedIndex}, blindEvaluator] = greyWolfOptimizer(blindEvaluator, ...
        lowerBounds, upperBounds, ...
        P.optimisation.populationSize, P.optimisation.maximumIterations, seedIndex);

    [awareRuns{seedIndex}, awareEvaluator] = greyWolfOptimizer(awareEvaluator, ...
        lowerBounds, upperBounds, ...
        P.optimisation.populationSize, P.optimisation.maximumIterations, seedIndex);

    fprintf('      seed %2d: blind $%.4fM   aware $%.4fM\n', seedIndex, ...
        blindRuns{seedIndex}.bestFitness/1e6, awareRuns{seedIndex}.bestFitness/1e6);
end
elapsed = toc(timerStart);
fprintf('      %.0f s total, cache hit rate blind %.1f%% / aware %.1f%%\n', elapsed, ...
    100*blindEvaluator.counters.cacheHits / max(blindEvaluator.counters.cacheHits + blindEvaluator.counters.evaluations, 1), ...
    100*awareEvaluator.counters.cacheHits / max(awareEvaluator.counters.cacheHits + awareEvaluator.counters.evaluations, 1));

% Best across seeds.
blindFitnesses = cellfun(@(r) r.bestFitness, blindRuns);
awareFitnesses = cellfun(@(r) r.bestFitness, awareRuns);
[~, blindBestIndex] = min(blindFitnesses);
[~, awareBestIndex] = min(awareFitnesses);
blindPosition = blindRuns{blindBestIndex}.bestPosition;
awarePosition = awareRuns{awareBestIndex}.bestPosition;

% =====================================================================
% 4. Four-cell comparison on identical traces
% =====================================================================
fprintf('\n[5/5] Scoring both designs on identical traces...\n');
[~, cellBlindBlind, scoringBlindDispatch] = evaluateFitness(scoringBlindDispatch, blindPosition);
[~, cellBlindAware, scoringAwareDispatch] = evaluateFitness(scoringAwareDispatch, blindPosition);
[~, cellAwareBlind, scoringBlindDispatch] = evaluateFitness(scoringBlindDispatch, awarePosition);
[~, cellAwareAware, scoringAwareDispatch] = evaluateFitness(scoringAwareDispatch, awarePosition);

% =====================================================================
% Report
% =====================================================================
printSizing('OUTAGE-BLIND DESIGN', cellBlindBlind);
printSizing('OUTAGE-AWARE DESIGN', cellAwareAware);

fprintf('\n---- Four cells, all scored on the SAME traces ----\n');
fprintf('%-34s %12s %14s  %s\n', 'cell', 'NPC ($M)', 'loss-of-load', 'verdict');
printCell('Blind sizing, blind dispatch', cellBlindBlind, lossOfLoadThreshold);
printCell('Blind sizing, aware dispatch', cellBlindAware, lossOfLoadThreshold);
printCell('Aware sizing, blind dispatch', cellAwareBlind, lossOfLoadThreshold);
printCell('Aware sizing, aware dispatch', cellAwareAware, lossOfLoadThreshold);

fprintf('\n---- Feasibility audit of returned winners ----\n');
awareFeasible = 0;
for seedIndex = 1:numberOfSeeds
    [~, outcome, awareEvaluator] = evaluateFitness(awareEvaluator, awareRuns{seedIndex}.bestPosition);
    if outcome.isFeasible; awareFeasible = awareFeasible + 1; end
end
fprintf('      aware design: %d/%d winners feasible\n', awareFeasible, numberOfSeeds);
fprintf('      seed spread: blind $%.0f, aware $%.0f (standard deviation)\n', ...
    std(blindFitnesses), std(awareFitnesses));

% =====================================================================
results.P                = P;
results.inputs           = inputs;
results.photovoltaic     = pv;
results.statistics       = statistics;
results.inSampleAvailable = inSampleAvailable;
results.inSampleCauses    = inSampleCauses;
results.blindRuns        = blindRuns;
results.awareRuns        = awareRuns;
results.blindPosition    = blindPosition;
results.awarePosition    = awarePosition;
results.cells = struct('blindBlind', cellBlindBlind, 'blindAware', cellBlindAware, ...
                       'awareBlind', cellAwareBlind, 'awareAware', cellAwareAware);
results.lossOfLoadThreshold = lossOfLoadThreshold;
results.blindPolicy = blindPolicy;
results.awarePolicy = awarePolicy;

if ~exist('results', 'dir'); mkdir('results'); end
save(fullfile('results', 'optimizerResults.mat'), 'results', '-v7.3');
fprintf('\nSaved to results/optimizerResults.mat\n\n');

end

% =====================================================================
function setupPaths()
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'config'));
addpath(fullfile(here, 'components'));
addpath(fullfile(here, 'dispatch'));
addpath(fullfile(here, 'optimizer'));
end

% =====================================================================
function printSizing(title, outcome)
s = outcome.sizing;
fprintf('\n---- %s ----\n', title);
fprintf('      %-42s %10.0f\n', 'photovoltaicCapacityKilowatts',        s.photovoltaicCapacityKilowatts);
fprintf('      %-42s %10.0f\n', 'batteryEnergyCapacityKilowattHours',   s.batteryEnergyCapacityKilowattHours);
fprintf('      %-42s %10.0f\n', 'generatorRatingKilowatts',             s.generatorRatingKilowatts);
fprintf('      %-42s %10.0f\n', 'inverterRatingKilowatts',              s.inverterRatingKilowatts);
fprintf('      %-42s %10.3f\n', 'netPresentCostMillionUsd',             outcome.meanNetPresentCostUsd/1e6);
fprintf('      %-42s %10.2f\n', 'levelisedCostBdtPerKilowattHour',      outcome.meanLevelisedCostUsdPerKilowattHour*122);
fprintf('      %-42s %10.5f\n', 'lossOfLoadProbabilityCritical',        outcome.meanLossOfLoadProbability);
fprintf('      %-42s %10.0f\n', 'annualDieselLitres',                   outcome.meanFuelLitres);
fprintf('      %-42s %10.3f\n', 'renewableFractionOfServedLoad',        outcome.meanRenewableFraction);
end

% =====================================================================
function printCell(label, outcome, threshold)
if outcome.meanLossOfLoadProbability > threshold + 1e-9
    verdict = 'INFEASIBLE';
else
    verdict = 'feasible';
end
fprintf('%-34s %12.4f %13.4f%%  %s\n', label, ...
    outcome.meanNetPresentCostUsd/1e6, outcome.meanLossOfLoadProbability*100, verdict);
end
