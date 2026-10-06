function results = runLandCostSweepV2(dataDirectory, landCostVectorUsdPerAcre, ...
                                     numberOfSeeds, lossOfLoadThreshold, basePosition)
%RUNLANDCOSTSWEEPV2  Sensitivity of optimal sizing and NPC to land cost (two-panel).
%
%   results = runLandCostSweepV2()
%   results = runLandCostSweepV2(dataDirectory, landCostVectorUsdPerAcre, ...
%                                numberOfSeeds, lossOfLoadThreshold, basePosition)
%
%   Defaults:
%       dataDirectory            = './data'
%       landCostVectorUsdPerAcre = 0:20000:200000  (11 points)
%       numberOfSeeds            = 5
%       lossOfLoadThreshold      = 0.01
%       basePosition             = automatically loaded from ./results/optimizerResults.mat
%                                  (results.cells.awareAware.sizing)
%
%   Same parameter as the original runLandCostSweep, but this version:
%     - Runs outage-AWARE only (not both blind and aware)
%     - Uses 50 max iterations (reduced from 75)
%     - Plots TWO panels: NPC and all 4 sizing variables
%     - Matches the output format of the other parameter sweep scripts
%
%   TIER 1 REGRET ANALYSIS: at every point, the FIXED basePosition design
%   (your actual base-case sizing) is also re-evaluated under that point's
%   land cost — no re-optimization, just one extra dispatch/economics pass
%   on the same evaluator. Regret is what it costs you to keep the base
%   design instead of re-sizing:
%       regret(x) = NPC_baseDesign(x) - NPC_reoptimized(x)      [should be >= 0]
%
%   Outputs:
%       results/landCostSweepV2.mat   — full results struct (incl. regret)
%       results/landCostSweepV2.png   — ONE figure, 3 stacked panels:
%                                       NPC, sizing, and regret — shown together

if nargin < 1 || isempty(dataDirectory);            dataDirectory = fullfile('.', 'data'); end
if nargin < 2 || isempty(landCostVectorUsdPerAcre); landCostVectorUsdPerAcre = 0:20000:200000; end
if nargin < 3 || isempty(numberOfSeeds);            numberOfSeeds = 5; end
if nargin < 4 || isempty(lossOfLoadThreshold);      lossOfLoadThreshold = 0.01; end
if nargin < 5 || isempty(basePosition);       basePosition = loadBasePositionFromOptimizerResults(); end

SWEEP_MAX_ITERATIONS = 50;

setupPaths();
P = microgridParameters();

fprintf('\n================================================================\n');
fprintf('  LAND COST SENSITIVITY SWEEP (V2 — two-panel, aware-only)\n');
fprintf('================================================================\n');
fprintf('  points:      %d (from $%.0fk to $%.0fk per acre, step $%.0fk)\n', ...
    numel(landCostVectorUsdPerAcre), ...
    landCostVectorUsdPerAcre(1)/1000, ...
    landCostVectorUsdPerAcre(end)/1000, ...
    (landCostVectorUsdPerAcre(2)-landCostVectorUsdPerAcre(1))/1000);
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
fprintf('\n[2/3] Sweeping land cost (outage-aware only)...\n');

numberOfPoints = numel(landCostVectorUsdPerAcre);
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
    thisLandCost = landCostVectorUsdPerAcre(pointIndex);

    Ppoint = P;
    Ppoint.costs.landPurchaseCostUsdPerAcre = thisLandCost;

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

    fprintf('   point %2d/%2d: $%6.0f/acre -> PV %5.0f kW, BESS %5.0f kWh, NPC $%.2fM | regret $%.3fM (%.1f%%)  [%.0fs]\n', ...
        pointIndex, numberOfPoints, thisLandCost, ...
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

xAxisThousands = landCostVectorUsdPerAcre / 1000;

figureHandle = figure('Name', 'Land Cost Sensitivity (V2)', ...
                      'Color', 'white', 'Position', [100 100 1100 1000]);

subplot(3,1,1);
plot(xAxisThousands, netPresentCost/1e6, '-s', 'LineWidth', 1.8, ...
    'MarkerSize', 7, 'MarkerFaceColor', [0.2 0.4 0.8], 'Color', [0.2 0.4 0.8]);
grid on; box on;
xlabel('Land purchase cost (USD/acre, thousands)');
ylabel('Net present cost (million USD)');
title(sprintf('NPC vs land cost (%d points, %d seeds, LOLP < %.1f%%)', ...
    numberOfPoints, numberOfSeeds, lossOfLoadThreshold*100));
xlim([xAxisThousands(1) xAxisThousands(end)]);

subplot(3,1,2);
yyaxis left;
plot(xAxisThousands, pvKilowatts, '-o', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'PV (kW_p)');
hold on;
plot(xAxisThousands, dieselKilowatts, '-^', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'Diesel (kW)');
plot(xAxisThousands, inverterKilowatts, '-d', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'Inverter (kW)');
ylabel('Capacity (kW)');

yyaxis right;
plot(xAxisThousands, batteryKilowattHours, '-s', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'Battery (kWh)');
ylabel('Battery energy (kWh)');

grid on; box on;
xlabel('Land purchase cost (USD/acre, thousands)');
title('Optimal component sizing vs land cost');
legend('Location', 'best');
xlim([xAxisThousands(1) xAxisThousands(end)]);

subplot(3,1,3);
plot(xAxisThousands, regretUsd/1e6, '-o', 'LineWidth', 1.8, 'MarkerSize', 6, ...
    'Color', [0.85 0.33 0.10], 'MarkerFaceColor', [0.85 0.33 0.10]);
hold on; yline(0, 'k--', 'LineWidth', 1);
grid on; box on;
xlabel('Land purchase cost (USD/acre, thousands)');
ylabel('Regret (million USD)');
title(sprintf('Regret of keeping the fixed base design (PV %.0f kW, BESS %.0f kWh, Diesel %.0f kW, Inverter %.0f kW)', ...
    basePosition(1), basePosition(2), basePosition(3), basePosition(4)));
xlim([xAxisThousands(1) xAxisThousands(end)]);

if ~exist('results', 'dir'); mkdir('results'); end

results.sweepParameter            = 'landPurchaseCostUsdPerAcre';
results.sweepVector               = landCostVectorUsdPerAcre(:);
results.sweepUnit                 = 'USD/acre';
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

save(fullfile('results', 'landCostSweepV2.mat'), 'results', '-v7.3');
try saveas(figureHandle, fullfile('results', 'landCostSweepV2.png'));
catch; fprintf('   (could not save PNG)\n'); end

fprintf('\nSaved:\n   results/landCostSweepV2.mat\n   results/landCostSweepV2.png\n\n');
end

function setupPaths()
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'config'));
addpath(fullfile(here, 'components'));
addpath(fullfile(here, 'dispatch'));
addpath(fullfile(here, 'optimizer'));
end
