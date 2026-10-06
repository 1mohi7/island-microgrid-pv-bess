function results = runBatteryCapexSweep(dataDirectory, batteryCapexVector, ...
                                       numberOfSeeds, lossOfLoadThreshold, basePosition)
%RUNBATTERYCAPEXSWEEP  Sensitivity of optimal sizing and NPC to battery energy capex.
%
%   results = runBatteryCapexSweep()
%   results = runBatteryCapexSweep(dataDirectory, batteryCapexVector, ...
%                                  numberOfSeeds, lossOfLoadThreshold, basePosition)
%
%   Defaults:
%       dataDirectory       = './data'
%       batteryCapexVector  = 200:25:400   (USD/kWh, 9 points)
%       numberOfSeeds       = 5
%       lossOfLoadThreshold = 0.01
%       basePosition        = automatically loaded from ./results/optimizerResults.mat
%                             (results.cells.awareAware.sizing)
%
%   Sweeps batteryEnergyCapitalCostUsdPerKilowattHour. Battery energy capex
%   enters the NPC through capital, replacement and O&M (which is a fraction
%   of energy capital). Power-conversion capex ($/kW) is held at baseline.
%
%   TIER 1 REGRET ANALYSIS: at every point, the FIXED basePosition design
%   (your actual base-case sizing) is also re-evaluated under that point's
%   parameters — no re-optimization, just one extra dispatch/economics pass
%   on the same evaluator. Regret is what it costs you to keep the base
%   design instead of re-sizing:
%       regret(x) = NPC_baseDesign(x) - NPC_reoptimized(x)      [should be >= 0]
%
%   Outputs:
%       results/batteryCapexSweep.mat   — full results struct (incl. regret)
%       results/batteryCapexSweep.png   — ONE figure, 3 stacked panels:
%                                         NPC, sizing, and regret — shown together

if nargin < 1 || isempty(dataDirectory);      dataDirectory = fullfile('.', 'data'); end
if nargin < 2 || isempty(batteryCapexVector); batteryCapexVector = 200:25:400; end
if nargin < 3 || isempty(numberOfSeeds);      numberOfSeeds = 5; end
if nargin < 4 || isempty(lossOfLoadThreshold); lossOfLoadThreshold = 0.01; end
if nargin < 5 || isempty(basePosition);       basePosition = loadBasePositionFromOptimizerResults(); end

SWEEP_MAX_ITERATIONS = 50;

setupPaths();
P = microgridParameters();

fprintf('\n================================================================\n');
fprintf('  BATTERY ENERGY CAPEX SENSITIVITY SWEEP\n');
fprintf('================================================================\n');
fprintf('  points:      %d (from $%.0f to $%.0f per kWh, step $%.0f)\n', ...
    numel(batteryCapexVector), batteryCapexVector(1), batteryCapexVector(end), ...
    batteryCapexVector(2)-batteryCapexVector(1));
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
fprintf('\n[2/3] Sweeping battery energy capex (outage-aware only)...\n');

numberOfPoints = numel(batteryCapexVector);
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
    thisCapex = batteryCapexVector(pointIndex);

    Ppoint = P;
    Ppoint.costs.batteryEnergyCapitalCostUsdPerKilowattHour = thisCapex;

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

    fprintf('   point %2d/%2d: $%4.0f/kWh -> BESS %5.0f kWh, PV %5.0f kW, NPC $%.2fM | regret $%.3fM (%.1f%%)  [%.0fs]\n', ...
        pointIndex, numberOfPoints, thisCapex, ...
        batteryKilowattHours(pointIndex), pvKilowatts(pointIndex), ...
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

figureHandle = figure('Name', 'Battery Capex Sensitivity', ...
                      'Color', 'white', 'Position', [100 100 1100 1000]);

subplot(3,1,1);
plot(batteryCapexVector, netPresentCost/1e6, '-s', 'LineWidth', 1.8, ...
    'MarkerSize', 7, 'MarkerFaceColor', [0.2 0.4 0.8], 'Color', [0.2 0.4 0.8]);
grid on; box on;
xlabel('Battery energy capital cost (USD/kWh)');
ylabel('Net present cost (million USD)');
title(sprintf('NPC vs battery energy capex (%d points, %d seeds, LOLP < %.1f%%)', ...
    numberOfPoints, numberOfSeeds, lossOfLoadThreshold*100));

subplot(3,1,2);
yyaxis left;
plot(batteryCapexVector, pvKilowatts, '-o', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'PV (kW_p)');
hold on;
plot(batteryCapexVector, dieselKilowatts, '-^', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'Diesel (kW)');
plot(batteryCapexVector, inverterKilowatts, '-d', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'Inverter (kW)');
ylabel('Capacity (kW)');

yyaxis right;
plot(batteryCapexVector, batteryKilowattHours, '-s', 'LineWidth', 1.6, 'MarkerSize', 5, ...
    'DisplayName', 'Battery (kWh)');
ylabel('Battery energy (kWh)');

grid on; box on;
xlabel('Battery energy capital cost (USD/kWh)');
title('Optimal component sizing vs battery energy capex');
legend('Location', 'best');

subplot(3,1,3);
plot(batteryCapexVector, regretUsd/1e6, '-o', 'LineWidth', 1.8, 'MarkerSize', 6, ...
    'Color', [0.85 0.33 0.10], 'MarkerFaceColor', [0.85 0.33 0.10]);
hold on; yline(0, 'k--', 'LineWidth', 1);
grid on; box on;
xlabel('Battery energy capital cost (USD/kWh)');
ylabel('Regret (million USD)');
title(sprintf('Regret of keeping the fixed base design (PV %.0f kW, BESS %.0f kWh, Diesel %.0f kW, Inverter %.0f kW)', ...
    basePosition(1), basePosition(2), basePosition(3), basePosition(4)));

if ~exist('results', 'dir'); mkdir('results'); end

results.sweepParameter            = 'batteryEnergyCapitalCostUsdPerKilowattHour';
results.sweepVector               = batteryCapexVector(:);
results.sweepUnit                 = 'USD/kWh';
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

save(fullfile('results', 'batteryCapexSweep.mat'), 'results', '-v7.3');
try saveas(figureHandle, fullfile('results', 'batteryCapexSweep.png'));
catch; fprintf('   (could not save PNG)\n'); end

fprintf('\nSaved:\n   results/batteryCapexSweep.mat\n   results/batteryCapexSweep.png\n\n');
end

function setupPaths()
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'config'));
addpath(fullfile(here, 'components'));
addpath(fullfile(here, 'dispatch'));
addpath(fullfile(here, 'optimizer'));
end
