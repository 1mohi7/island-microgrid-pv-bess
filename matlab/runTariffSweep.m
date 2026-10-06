function results = runTariffSweep(dataDirectory, tariffVector, ...
                                  numberOfSeeds, lossOfLoadThreshold, basePosition)
%RUNTARIFFSWEEP  Sensitivity of optimal sizing and NPC to grid import tariff.
%
%   results = runTariffSweep()
%   results = runTariffSweep(dataDirectory, tariffVector, ...
%                            numberOfSeeds, lossOfLoadThreshold, basePosition)
%
%   Defaults:
%       dataDirectory    = './data'
%       tariffVector     = 8.0:0.5:13.0   (BDT/kWh, 11 points)
%       numberOfSeeds    = 5
%       lossOfLoadThreshold = 0.01
%       basePosition     = automatically loaded from ./results/optimizerResults.mat
%                          (results.cells.awareAware.sizing)
%
%   Sweeps importTariffBdtPerKilowattHour. The import tariff enters the NPC
%   through 25-year grid energy cost (with real escalation) AND through the
%   PV degradation makeup cost (lost output bought at the prevailing tariff).
%   The export credit rate is NOT swept here — it is separate.
%
%   NOTE: Higher tariff makes self-generation more attractive, so expect PV
%   and battery to grow with tariff while NPC (dominated by grid purchases)
%   also rises.
%
%   TIER 1 REGRET ANALYSIS: at every point, the FIXED basePosition design
%   (your actual base-case sizing) is also re-evaluated under that point's
%   parameters — no re-optimization, just one extra dispatch/economics pass
%   on the same evaluator. Regret is what it costs you to keep the base
%   design instead of re-sizing:
%       regret(x) = NPC_baseDesign(x) - NPC_reoptimized(x)      [should be >= 0]
%
%   Outputs:
%       results/tariffSweep.mat   — full results struct (incl. regret)
%       results/tariffSweep.png   — ONE figure, 3 stacked panels:
%                                   NPC, sizing, and regret — shown together

if nargin < 1 || isempty(dataDirectory);    dataDirectory = fullfile('.', 'data'); end
if nargin < 2 || isempty(tariffVector);     tariffVector = 8.0:0.5:13.0; end
if nargin < 3 || isempty(numberOfSeeds);    numberOfSeeds = 5; end
if nargin < 4 || isempty(lossOfLoadThreshold); lossOfLoadThreshold = 0.01; end
if nargin < 5 || isempty(basePosition);       basePosition = loadBasePositionFromOptimizerResults(); end

SWEEP_MAX_ITERATIONS = 50;

setupPaths();
P = microgridParameters();

fprintf('\n================================================================\n');
fprintf('  GRID IMPORT TARIFF SENSITIVITY SWEEP\n');
fprintf('================================================================\n');
fprintf('  points:      %d (from %.1f to %.1f BDT/kWh, step %.1f)\n', ...
    numel(tariffVector), tariffVector(1), tariffVector(end), ...
    tariffVector(2)-tariffVector(1));
fprintf('  seeds: %d   pop: %d   iter: %d   traces: %d\n', ...
    numberOfSeeds, P.optimisation.populationSize, ...
    SWEEP_MAX_ITERATIONS, P.optimisation.numberOfInSampleTraces);
fprintf('  threshold: %.3f\n', lossOfLoadThreshold);

% =====================================================================
% 1. Build the once-only pieces
% =====================================================================
fprintf('\n[1/3] Loading inputs, building PV profile, sampling outage traces...\n');
inputs     = loadFeederInputs(dataDirectory, P);
pv         = photovoltaicModel(inputs, P);
statistics = outageModel(inputs, P);

numberOfTraces    = P.optimisation.numberOfInSampleTraces;
inSampleAvailable = zeros(numberOfTraces, P.site.hoursPerYear);
inSampleCauses    = zeros(numberOfTraces, P.site.hoursPerYear);
for traceIndex = 1:numberOfTraces
    [available, causes] = sampleOutageTrace(statistics, ...
        P.optimisation.inSampleTraceSeed + traceIndex - 1, P);
    inSampleAvailable(traceIndex, :) = available';
    inSampleCauses(traceIndex, :)    = causes';
end

lowerBounds = [P.optimisation.photovoltaicCapacityBoundsKilowatts(1), ...
               P.optimisation.batteryEnergyCapacityBoundsKilowattHours(1), ...
               P.optimisation.generatorRatingBoundsKilowatts(1), ...
               P.optimisation.inverterRatingBoundsKilowatts(1)];
upperBounds = [P.optimisation.photovoltaicCapacityBoundsKilowatts(2), ...
               P.optimisation.batteryEnergyCapacityBoundsKilowattHours(2), ...
               P.optimisation.generatorRatingBoundsKilowatts(2), ...
               P.optimisation.inverterRatingBoundsKilowatts(2)];

% =====================================================================
% 2. Sweep
% =====================================================================
fprintf('\n[2/3] Sweeping grid import tariff (outage-aware only)...\n');

numberOfPoints = numel(tariffVector);
pvKilowatts         = nan(numberOfPoints, 1);
batteryKilowattHours = nan(numberOfPoints, 1);
dieselKilowatts     = nan(numberOfPoints, 1);
inverterKilowatts   = nan(numberOfPoints, 1);
netPresentCost      = nan(numberOfPoints, 1);
lcoe                = nan(numberOfPoints, 1);
lolp                = nan(numberOfPoints, 1);
feasibility         = false(numberOfPoints, 1);
sizingCell          = cell(numberOfPoints, 1);
baseNetPresentCost  = nan(numberOfPoints, 1);
baseLolp            = nan(numberOfPoints, 1);
baseFeasibility     = false(numberOfPoints, 1);
regretUsd           = nan(numberOfPoints, 1);
regretPercent       = nan(numberOfPoints, 1);

sweepTimer = tic;
for pointIndex = 1:numberOfPoints
    thisTariff = tariffVector(pointIndex);

    Ppoint = P;
    Ppoint.tariff.importTariffBdtPerKilowattHour = thisTariff;

    awarePolicy = reservePolicy('aware', statistics, inputs, Ppoint, 6);
    awareEvaluator = fitnessEvaluator(inputs, pv.generationPerInstalledKilowatt, ...
        inSampleAvailable, inSampleCauses, awarePolicy, ...
        lossOfLoadThreshold, Ppoint, true, true);

    bestFitness = inf;  bestPosition = [];
    for seedIndex = 1:numberOfSeeds
        [run, awareEvaluator] = greyWolfOptimizer(awareEvaluator, ...
            lowerBounds, upperBounds, ...
            Ppoint.optimisation.populationSize, ...
            SWEEP_MAX_ITERATIONS, seedIndex);
        if run.bestFitness < bestFitness
            bestFitness  = run.bestFitness;
            bestPosition = run.bestPosition;
        end
    end

    [~, outcome, ~] = evaluateFitness(awareEvaluator, bestPosition);

    pvKilowatts(pointIndex)          = outcome.sizing.photovoltaicCapacityKilowatts;
    batteryKilowattHours(pointIndex) = outcome.sizing.batteryEnergyCapacityKilowattHours;
    dieselKilowatts(pointIndex)      = outcome.sizing.generatorRatingKilowatts;
    inverterKilowatts(pointIndex)    = outcome.sizing.inverterRatingKilowatts;
    netPresentCost(pointIndex)       = outcome.meanNetPresentCostUsd;
    lcoe(pointIndex)                 = outcome.meanLevelisedCostUsdPerKilowattHour;
    lolp(pointIndex)                 = outcome.meanLossOfLoadProbability;
    feasibility(pointIndex)          = outcome.isFeasible;
    sizingCell{pointIndex}           = outcome.sizing;

    % --- Tier 1 regret: re-score the FIXED base design under this point's
    % parameters using the same evaluator (no re-optimization). ---
    [~, baseOutcome, ~] = evaluateFitness(awareEvaluator, basePosition);
    baseNetPresentCost(pointIndex) = baseOutcome.meanNetPresentCostUsd;
    baseLolp(pointIndex)           = baseOutcome.meanLossOfLoadProbability;
    baseFeasibility(pointIndex)    = baseOutcome.isFeasible;
    regretUsd(pointIndex)          = baseNetPresentCost(pointIndex) - netPresentCost(pointIndex);
    regretPercent(pointIndex)      = 100 * regretUsd(pointIndex) / netPresentCost(pointIndex);

    fprintf('   point %2d/%2d: %.1f BDT/kWh -> PV %5.0f kW, BESS %5.0f kWh, NPC $%.2fM | regret $%.3fM (%.1f%%)  [%.0fs]\n', ...
        pointIndex, numberOfPoints, thisTariff, ...
        pvKilowatts(pointIndex), batteryKilowattHours(pointIndex), ...
        netPresentCost(pointIndex)/1e6, regretUsd(pointIndex)/1e6, regretPercent(pointIndex), ...
        toc(sweepTimer));
end
elapsedTotal = toc(sweepTimer);
fprintf('\n   sweep done in %.1f min (%.0f s)\n', elapsedTotal/60, elapsedTotal);

sizing = [sizingCell{:}]';

% =====================================================================
% 3. Plot and save
% =====================================================================
fprintf('\n[3/3] Plotting...\n');

figureHandle = figure('Name', 'Import Tariff Sensitivity', ...
                      'Color', 'white', 'Position', [100 100 1100 1000]);

subplot(3,1,1);
plot(tariffVector, netPresentCost/1e6, '-s', 'LineWidth', 1.8, ...
    'MarkerSize', 7, 'MarkerFaceColor', [0.2 0.4 0.8], 'Color', [0.2 0.4 0.8]);
grid on; box on;
xlabel('Grid import tariff (BDT/kWh)');
ylabel('Net present cost (million USD)');
title(sprintf('NPC vs grid import tariff (%d points, %d seeds, LOLP < %.1f%%)', ...
    numberOfPoints, numberOfSeeds, lossOfLoadThreshold*100));

subplot(3,1,2);
yyaxis left;
plot(tariffVector, pvKilowatts, '-o', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'PV (kW_p)');
hold on;
plot(tariffVector, dieselKilowatts, '-^', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'Diesel (kW)');
plot(tariffVector, inverterKilowatts, '-d', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'Inverter (kW)');
ylabel('Capacity (kW)');

yyaxis right;
plot(tariffVector, batteryKilowattHours, '-s', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'Battery (kWh)');
ylabel('Battery energy (kWh)');

grid on; box on;
xlabel('Grid import tariff (BDT/kWh)');
title('Optimal component sizing vs grid import tariff');
legend('Location', 'best');

subplot(3,1,3);
plot(tariffVector, regretUsd/1e6, '-o', 'LineWidth', 1.8, 'MarkerSize', 6, ...
    'Color', [0.85 0.33 0.10], 'MarkerFaceColor', [0.85 0.33 0.10]);
hold on; yline(0, 'k--', 'LineWidth', 1);
grid on; box on;
xlabel('Grid import tariff (BDT/kWh)');
ylabel('Regret (million USD)');
title(sprintf('Regret of keeping the fixed base design (PV %.0f kW, BESS %.0f kWh, Diesel %.0f kW, Inverter %.0f kW)', ...
    basePosition(1), basePosition(2), basePosition(3), basePosition(4)));

if ~exist('results', 'dir'); mkdir('results'); end

results.sweepParameter            = 'importTariffBdtPerKilowattHour';
results.sweepVector               = tariffVector(:);
results.sweepUnit                 = 'BDT/kWh';
results.pvKilowatts               = pvKilowatts;
results.batteryKilowattHours      = batteryKilowattHours;
results.dieselKilowatts           = dieselKilowatts;
results.inverterKilowatts         = inverterKilowatts;
results.netPresentCost            = netPresentCost;
results.lcoe                      = lcoe;
results.lolp                      = lolp;
results.feasibility               = feasibility;
results.sizing                    = sizing;
results.numberOfSeeds             = numberOfSeeds;
results.lossOfLoadThreshold       = lossOfLoadThreshold;
results.maximumIterations         = SWEEP_MAX_ITERATIONS;
results.populationSize            = P.optimisation.populationSize;
results.numberOfInSampleTraces    = P.optimisation.numberOfInSampleTraces;
results.elapsedSeconds            = elapsedTotal;
results.basePosition              = basePosition(:)';
results.baseNetPresentCost        = baseNetPresentCost;
results.baseLolp                  = baseLolp;
results.baseFeasibility           = baseFeasibility;
results.regretUsd                 = regretUsd;
results.regretPercent             = regretPercent;

save(fullfile('results', 'tariffSweep.mat'), 'results', '-v7.3');
try saveas(figureHandle, fullfile('results', 'tariffSweep.png'));
catch; fprintf('   (could not save PNG)\n'); end

fprintf('\nSaved:\n   results/tariffSweep.mat\n   results/tariffSweep.png\n\n');
end

function setupPaths()
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'config'));
addpath(fullfile(here, 'components'));
addpath(fullfile(here, 'dispatch'));
addpath(fullfile(here, 'optimizer'));
end
