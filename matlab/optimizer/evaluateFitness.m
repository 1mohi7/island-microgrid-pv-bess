function [fitness, outcome, evaluator] = evaluateFitness(evaluator, position)
%EVALUATEFITNESS  One fitness evaluation: dispatch across traces, economics, penalty.
%
%   [fitness, outcome, evaluator] = evaluateFitness(evaluator, position)
%
%   The evaluator is returned so that its counters stay current. The cache is a
%   containers.Map with handle semantics, so cached entries persist without
%   needing the struct back.

P = evaluator.P;
sizing = snapPositionToSizing(position, P);

key = sprintf('%.0f_%.0f_%.0f_%.0f', ...
    sizing.photovoltaicCapacityKilowatts, ...
    sizing.batteryEnergyCapacityKilowattHours, ...
    sizing.generatorRatingKilowatts, ...
    sizing.inverterRatingKilowatts);

if isKey(evaluator.cache, key)
    outcome = evaluator.cache(key);
    fitness = outcome.fitnessUsd;
    evaluator.counters.cacheHits = evaluator.counters.cacheHits + 1;
    return;
end

photovoltaicGeneration = evaluator.photovoltaicPerKilowatt * ...
                         sizing.photovoltaicCapacityKilowatts;

numberOfTraces = size(evaluator.gridAvailableMatrix, 1);
netPresentCosts        = zeros(numberOfTraces, 1);
levelisedCosts         = zeros(numberOfTraces, 1);
lossOfLoadProbabilities = zeros(numberOfTraces, 1);
unservedCritical       = zeros(numberOfTraces, 1);
unservedByCause        = zeros(numberOfTraces, 4);
fuelLitres             = zeros(numberOfTraces, 1);
generatorHours         = zeros(numberOfTraces, 1);
gridImport             = zeros(numberOfTraces, 1);
gridExport             = zeros(numberOfTraces, 1);
curtailed              = zeros(numberOfTraces, 1);
renewableFraction      = zeros(numberOfTraces, 1);
directPvFraction       = zeros(numberOfTraces, 1);
equivalentCycles       = zeros(numberOfTraces, 1);
carbonTonnes           = zeros(numberOfTraces, 1);
lastEconomics = [];

for traceIndex = 1:numberOfTraces
    gridAvailable = evaluator.gridAvailableMatrix(traceIndex, :)';
    causeCodes    = evaluator.outageCauseMatrix(traceIndex, :)';

    reserveProfile = evaluator.policy.buildProfile( ...
        sizing.batteryEnergyCapacityKilowattHours, causeCodes);

    dispatchResult = dispatchSimulator(photovoltaicGeneration, evaluator.inputs, ...
        gridAvailable, causeCodes, reserveProfile, sizing, P, ...
        evaluator.allowGridCharging);

    economics = economicsModel(sizing, dispatchResult, P);
    lastEconomics = economics;

    netPresentCosts(traceIndex)         = economics.netPresentCostUsd;
    levelisedCosts(traceIndex)          = economics.levelisedCostUsdPerKilowattHour;
    lossOfLoadProbabilities(traceIndex) = dispatchResult.lossOfLoadProbabilityCritical;
    unservedCritical(traceIndex)        = dispatchResult.unservedCriticalKilowattHours;
    unservedByCause(traceIndex, :)      = dispatchResult.unservedCriticalByCauseKilowattHours';
    fuelLitres(traceIndex)              = dispatchResult.fuelConsumedLitres;
    generatorHours(traceIndex)          = dispatchResult.generatorRunningHours;
    gridImport(traceIndex)              = dispatchResult.gridImportKilowattHours;
    gridExport(traceIndex)              = dispatchResult.gridExportKilowattHours;
    curtailed(traceIndex)               = dispatchResult.curtailedKilowattHours;
    renewableFraction(traceIndex)       = dispatchResult.renewableFraction;
    directPvFraction(traceIndex)        = dispatchResult.directPhotovoltaicFraction;
    equivalentCycles(traceIndex)        = dispatchResult.equivalentFullCyclesPerYear;
    carbonTonnes(traceIndex)            = economics.carbonDioxideTonnesPerYear;
end

meanNetPresentCost = mean(netPresentCosts);
meanLossOfLoad     = mean(lossOfLoadProbabilities);

violation = 0;
if evaluator.enforceConstraint
    violation = max(0, meanLossOfLoad - evaluator.lossOfLoadThreshold);
end

fitness = meanNetPresentCost ...
        + P.optimisation.constraintPenaltyLinearWeightUsd * violation ...
        + P.optimisation.constraintPenaltyQuadraticWeightUsd * violation^2;

outcome.sizing                    = sizing;
outcome.fitnessUsd                = fitness;
outcome.meanNetPresentCostUsd     = meanNetPresentCost;
outcome.netPresentCostByTraceUsd  = netPresentCosts;
outcome.meanLossOfLoadProbability = meanLossOfLoad;
outcome.worstLossOfLoadProbability = max(lossOfLoadProbabilities);
outcome.constraintViolation       = violation;
outcome.isFeasible                = violation <= 0;
outcome.meanLevelisedCostUsdPerKilowattHour = mean(levelisedCosts);
outcome.meanUnservedCriticalKilowattHours   = mean(unservedCritical);
outcome.meanUnservedByCauseKilowattHours    = mean(unservedByCause, 1);
outcome.meanFuelLitres            = mean(fuelLitres);
outcome.meanGeneratorRunningHours = mean(generatorHours);
outcome.meanGridImportKilowattHours = mean(gridImport);
outcome.meanGridExportKilowattHours = mean(gridExport);
outcome.meanCurtailedKilowattHours  = mean(curtailed);
outcome.meanRenewableFraction     = mean(renewableFraction);
outcome.meanEquivalentFullCycles  = mean(equivalentCycles);
outcome.meanCarbonDioxideTonnes   = mean(carbonTonnes);
% AUDIT FIX (item 1): this is the economics of the LAST trace only, kept for
% its cost BREAKDOWN. Never read outcome.economics.netPresentCostUsd as "the"
% NPC: the optimizer uses outcome.meanNetPresentCostUsd.
outcome.economics                 = lastEconomics;
outcome.economicsIsLastTraceOnly  = true;
outcome.directPhotovoltaicFraction = mean(directPvFraction);

evaluator.cache(key) = outcome;
evaluator.counters.evaluations = evaluator.counters.evaluations + 1;

end
