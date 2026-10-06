function sensitivity = runFixedDesignCostSensitivity(optimizerResultsFile, outputFolder)
%RUNFIXEDDESIGNCOSTSENSITIVITY  Fixed-design economic sensitivity, +/-20% in 5% steps.
%
%   sensitivity = runFixedDesignCostSensitivity()
%   sensitivity = runFixedDesignCostSensitivity(optimizerResultsFile, outputFolder)
%
% PURPOSE
%   Tests how much the FINAL outage-aware design's NPC changes when important
%   economic assumptions change, WITHOUT re-optimising the design.
%
%   The design is loaded automatically from:
%       results.cells.awareAware.sizing
%   inside optimizerResults.mat.
%
%   Each cost parameter is varied independently at:
%       -20, -15, -10, -5, 0, +5, +10, +15, +20 percent
%
%   The exact same fixed PV/BESS/DG/inverter sizing, outage traces and aware
%   dispatch policy are used at every point. There is NO Grey Wolf Optimizer
%   call in this script.
%
% PARAMETERS TESTED
%   1) PV CAPEX              [USD/kWp]
%   2) BESS energy CAPEX     [USD/kWh]
%   3) Diesel-generator CAPEX[USD/kW]
%   4) Land purchase cost    [USD/acre]
%   5) Diesel fuel price     [BDT/L]
%   6) Grid import tariff    [BDT/kWh]
%   7) Real discount rate    [fraction; varied relatively]
%
% OUTPUTS
%   results/fixedDesignCostSensitivity/fixedDesignCostSensitivity.mat
%   results/fixedDesignCostSensitivity/fixedDesignCostSensitivity.csv
%   results/fixedDesignCostSensitivity/fixedDesignCostSensitivity_summary.csv
%   results/fixedDesignCostSensitivity/fixedDesignCostSensitivity_page1.png
%   results/fixedDesignCostSensitivity/fixedDesignCostSensitivity_page2.png
%   results/fixedDesignCostSensitivity/fixedDesignCostSensitivity_page3.png
%   results/fixedDesignCostSensitivity/fixedDesignCostSensitivity_all_pages.pdf
%
% FIGURES
%   Seven separate parameter graphs are created, arranged three graphs per page:
%      Page 1: parameters 1-3
%      Page 2: parameters 4-6
%      Page 3: parameter 7
%   Every marker is labelled with the exact NPC change from the base case.
%   Each subplot title contains ONLY the parameter name and (+/-20%).
%
% ROBUSTNESS RULE
%   By default, a parameter is marked "holds" when the maximum absolute NPC
%   change over the full +/-20% range is <= 1% of the base NPC.
%
% IMPORTANT INTERPRETATION
%   This is FIXED-DESIGN economic sensitivity. It answers:
%       "How much does the NPC of our selected design move if costs change?"
%   It does NOT prove that the same sizing would still be globally optimal;
%   that requires the separate re-optimisation/regret sweeps.

if nargin < 1 || isempty(optimizerResultsFile)
    optimizerResultsFile = fullfile('.', 'results', 'optimizerResults.mat');
end
if nargin < 2 || isempty(outputFolder)
    outputFolder = fullfile('.', 'results', 'fixedDesignCostSensitivity');
end

VARIATION_PERCENT = (-20:5:20)';
ROBUSTNESS_LIMIT_PERCENT = 1.0;

setupPaths();
if ~exist(outputFolder, 'dir'); mkdir(outputFolder); end

%% ---------------------------------------------------------------- load result
fprintf('\n==============================================================\n');
fprintf('  FIXED-DESIGN COST SENSITIVITY: +/-20%% IN 5%% STEPS\n');
fprintf('==============================================================\n');

loaded = load(optimizerResultsFile);
assert(isfield(loaded, 'results'), ...
    'The MAT file must contain a variable named results.');
r = loaded.results;

requiredFields = {'P','inputs','photovoltaic','statistics', ...
                  'inSampleAvailable','inSampleCauses','cells', ...
                  'lossOfLoadThreshold'};
for k = 1:numel(requiredFields)
    assert(isfield(r, requiredFields{k}), ...
        'optimizerResults.mat is missing results.%s.', requiredFields{k});
end
assert(isfield(r.cells, 'awareAware') && isfield(r.cells.awareAware, 'sizing'), ...
    'optimizerResults.mat is missing results.cells.awareAware.sizing.');

design = r.cells.awareAware.sizing;
basePosition = [design.photovoltaicCapacityKilowatts, ...
                design.batteryEnergyCapacityKilowattHours, ...
                design.generatorRatingKilowatts, ...
                design.inverterRatingKilowatts];

Pbase       = r.P;
inputs      = r.inputs;
pvPerKw     = r.photovoltaic.generationPerInstalledKilowatt;
statistics  = r.statistics;
gridMatrix  = r.inSampleAvailable;
causeMatrix = r.inSampleCauses;
lolpTarget  = r.lossOfLoadThreshold;

fprintf('  Loaded final outage-aware design:\n');
fprintf('    PV      : %.0f kW\n',  basePosition(1));
fprintf('    BESS    : %.0f kWh\n', basePosition(2));
fprintf('    Diesel  : %.0f kW\n',  basePosition(3));
fprintf('    GFM inv.: %.0f kW\n',  basePosition(4));
fprintf('  Variations: %s %%\n', sprintf('%+g ', VARIATION_PERCENT));
fprintf('  Robustness criterion: max |Delta NPC| <= %.2f%%\n', ROBUSTNESS_LIMIT_PERCENT);

%% ------------------------------------------------------- re-score base once
% Re-evaluate the saved design using the saved traces and current fixed code.
% This is the common reference NPC for ALL parameter sweeps.
basePolicy = reservePolicy('aware', statistics, inputs, Pbase, 6);
baseEvaluator = fitnessEvaluator(inputs, pvPerKw, gridMatrix, causeMatrix, ...
    basePolicy, lolpTarget, Pbase, true, true);
[~, baseOutcome, ~] = evaluateFitness(baseEvaluator, basePosition);

baseNpcUsd  = baseOutcome.meanNetPresentCostUsd;
baseLolp    = baseOutcome.meanLossOfLoadProbability;
storedNpcUsd = NaN;
if isfield(r.cells.awareAware, 'meanNetPresentCostUsd')
    storedNpcUsd = r.cells.awareAware.meanNetPresentCostUsd;
end

fprintf('\n  Base NPC re-evaluated : $%.3f million\n', baseNpcUsd/1e6);
fprintf('  Base LOLP             : %.5f%%\n', 100*baseLolp);
if ~isnan(storedNpcUsd)
    fprintf('  NPC stored in MAT     : $%.3f million\n', storedNpcUsd/1e6);
    if abs(storedNpcUsd - baseNpcUsd) > 1
        fprintf('  NOTE: current-code re-evaluation differs from stored NPC by $%.2f.\n', ...
            baseNpcUsd - storedNpcUsd);
    end
end

%% ------------------------------------------------------ parameter catalogue
% group = 1: capital-cost graph; group = 2: operating/financial graph
parameters = repmat(struct('name','', 'field','', 'unit','', 'group',0, 'baseDisplayValue',0), 1, 7);
parameters(1) = makeParameter('PV CAPEX', ...
    'photovoltaicCapitalCostUsdPerKilowattPeak', 'USD/kWp', 1, ...
    Pbase.costs.photovoltaicCapitalCostUsdPerKilowattPeak);
parameters(2) = makeParameter('BESS energy CAPEX', ...
    'batteryEnergyCapitalCostUsdPerKilowattHour', 'USD/kWh', 1, ...
    Pbase.costs.batteryEnergyCapitalCostUsdPerKilowattHour);
parameters(3) = makeParameter('Diesel-generator CAPEX', ...
    'dieselGeneratorCapitalCostUsdPerKilowatt', 'USD/kW', 1, ...
    Pbase.costs.dieselGeneratorCapitalCostUsdPerKilowatt);
parameters(4) = makeParameter('Land purchase cost', ...
    'landPurchaseCostUsdPerAcre', 'USD/acre', 1, ...
    Pbase.costs.landPurchaseCostUsdPerAcre);
parameters(5) = makeParameter('Diesel fuel price', ...
    'dieselFuelPriceBdtPerLitre', 'BDT/L', 2, ...
    Pbase.costs.dieselFuelPriceBdtPerLitre);
parameters(6) = makeParameter('Grid import tariff', ...
    'importTariffBdtPerKilowattHour', 'BDT/kWh', 2, ...
    Pbase.tariff.importTariffBdtPerKilowattHour);
parameters(7) = makeParameter('Real discount rate', ...
    'realDiscountRateFraction', '%', 2, ...
    100*Pbase.costs.realDiscountRateFraction);

nParam = numel(parameters);
nPoint = numel(VARIATION_PERCENT);

npcUsd          = nan(nPoint, nParam);
deltaNpcUsd     = nan(nPoint, nParam);
deltaNpcPercent = nan(nPoint, nParam);
actualValue     = nan(nPoint, nParam);
lolp            = nan(nPoint, nParam);
feasible        = false(nPoint, nParam);

%% ---------------------------------------------------------- fixed-design sweep
fprintf('\n--- Sweeping fixed design (NO re-optimization) ---\n');
startTimer = tic;

for p = 1:nParam
    fprintf('\n  %s (base = %s)\n', parameters(p).name, ...
        formatParameterValue(parameters(p).baseDisplayValue, parameters(p).unit));

    for i = 1:nPoint
        changePct = VARIATION_PERCENT(i);
        multiplier = 1 + changePct/100;

        Ppoint = Pbase;
        [Ppoint, actualDisplay] = applyParameterMultiplier(Ppoint, ...
            parameters(p).field, multiplier);
        actualValue(i,p) = actualDisplay;

        % Costs do not change the physical design. Rebuild the aware policy so
        % every evaluation is self-contained and uses the point's P struct.
        pointPolicy = reservePolicy('aware', statistics, inputs, Ppoint, 6);
        evaluator = fitnessEvaluator(inputs, pvPerKw, gridMatrix, causeMatrix, ...
            pointPolicy, lolpTarget, Ppoint, true, true);

        [~, outcome, ~] = evaluateFitness(evaluator, basePosition);

        npcUsd(i,p)          = outcome.meanNetPresentCostUsd;
        deltaNpcUsd(i,p)     = npcUsd(i,p) - baseNpcUsd;
        deltaNpcPercent(i,p) = 100 * deltaNpcUsd(i,p) / baseNpcUsd;
        lolp(i,p)            = outcome.meanLossOfLoadProbability;
        feasible(i,p)        = outcome.isFeasible;

        fprintf('    %+3.0f%% | %-18s | NPC $%10.2f | Delta $%+10.2f | Delta %+8.4f%%\n', ...
            changePct, formatParameterValue(actualDisplay, parameters(p).unit), ...
            npcUsd(i,p), deltaNpcUsd(i,p), deltaNpcPercent(i,p));
    end
end
elapsedSeconds = toc(startTimer);

%% -------------------------------------------------------------- long table
nRows = nParam * nPoint;
parameterName = cell(nRows,1);
parameterField = cell(nRows,1);
unit = cell(nRows,1);
variationPercent = zeros(nRows,1);
baseParameterValue = zeros(nRows,1);
modifiedParameterValue = zeros(nRows,1);
netPresentCostUsd = zeros(nRows,1);
changeInNpcUsd = zeros(nRows,1);
changeInNpcPercent = zeros(nRows,1);
lossOfLoadProbability = zeros(nRows,1);
isFeasible = false(nRows,1);

row = 0;
for p = 1:nParam
    for i = 1:nPoint
        row = row + 1;
        parameterName{row}            = parameters(p).name;
        parameterField{row}           = parameters(p).field;
        unit{row}                     = parameters(p).unit;
        variationPercent(row)         = VARIATION_PERCENT(i);
        baseParameterValue(row)       = parameters(p).baseDisplayValue;
        modifiedParameterValue(row)   = actualValue(i,p);
        netPresentCostUsd(row)        = npcUsd(i,p);
        changeInNpcUsd(row)           = deltaNpcUsd(i,p);
        changeInNpcPercent(row)       = deltaNpcPercent(i,p);
        lossOfLoadProbability(row)    = lolp(i,p);
        isFeasible(row)               = feasible(i,p);
    end
end

resultsTable = table(parameterName, parameterField, unit, variationPercent, ...
    baseParameterValue, modifiedParameterValue, netPresentCostUsd, ...
    changeInNpcUsd, changeInNpcPercent, lossOfLoadProbability, isFeasible);

%% ----------------------------------------------------------- summary table
summaryParameter = cell(nParam,1);
baseValue = zeros(nParam,1);
summaryUnit = cell(nParam,1);
maxAbsoluteNpcChangeUsd = zeros(nParam,1);
maxAbsoluteNpcChangePercent = zeros(nParam,1);
variationAtMaximumPercent = zeros(nParam,1);
baseDesignHolds = false(nParam,1);

for p = 1:nParam
    [maxAbsoluteNpcChangePercent(p), idx] = max(abs(deltaNpcPercent(:,p)));
    maxAbsoluteNpcChangeUsd(p) = abs(deltaNpcUsd(idx,p));
    variationAtMaximumPercent(p) = VARIATION_PERCENT(idx);
    baseDesignHolds(p) = maxAbsoluteNpcChangePercent(p) <= ROBUSTNESS_LIMIT_PERCENT;

    summaryParameter{p} = parameters(p).name;
    baseValue(p) = parameters(p).baseDisplayValue;
    summaryUnit{p} = parameters(p).unit;
end

summaryTable = table(summaryParameter, baseValue, summaryUnit, ...
    maxAbsoluteNpcChangeUsd, maxAbsoluteNpcChangePercent, ...
    variationAtMaximumPercent, baseDesignHolds);

%% ------------------------------------------------------------------ figures
% Seven single-parameter graphs, arranged three graphs per page.
% Titles intentionally contain ONLY the parameter name and (+/-20%).
pageGroups = {1:3, 4:6, 7};
figureHandles = gobjects(numel(pageGroups),1);

for pageIndex = 1:numel(pageGroups)
    parameterIndices = pageGroups{pageIndex};

    % Use a portrait-like page with three vertical graphs. The last page has
    % only one graph and is sized shorter so it does not leave excessive blank space.
    if numel(parameterIndices) == 3
        figPosition = [80 60 1200 1200];
    else
        figPosition = [80 120 1200 480];
    end

    fig = figure('Color','w', ...
        'Name', sprintf('Fixed-design cost sensitivity page %d', pageIndex), ...
        'Position', figPosition);
    figureHandles(pageIndex) = fig;

    tiledlayout(numel(parameterIndices), 1, ...
        'TileSpacing','compact', 'Padding','compact');

    for localIndex = 1:numel(parameterIndices)
        p = parameterIndices(localIndex);
        ax = nexttile;
        plotSingleParameterPanel(ax, VARIATION_PERCENT, ...
            deltaNpcPercent(:,p), parameters(p), ROBUSTNESS_LIMIT_PERCENT);
    end
end

%% ------------------------------------------------------------------- save
matFile = fullfile(outputFolder, 'fixedDesignCostSensitivity.mat');
csvFile = fullfile(outputFolder, 'fixedDesignCostSensitivity.csv');
summaryCsvFile = fullfile(outputFolder, 'fixedDesignCostSensitivity_summary.csv');
pdfFile = fullfile(outputFolder, 'fixedDesignCostSensitivity_all_pages.pdf');

sensitivity.optimizerResultsFile = optimizerResultsFile;
sensitivity.generatedOn = datestr(now, 'yyyy-mm-dd HH:MM:SS');
sensitivity.baseSizing = design;
sensitivity.basePosition = basePosition;
sensitivity.baseNpcUsd = baseNpcUsd;
sensitivity.storedBaseNpcUsd = storedNpcUsd;
sensitivity.baseLolp = baseLolp;
sensitivity.variationPercent = VARIATION_PERCENT;
sensitivity.robustnessLimitPercent = ROBUSTNESS_LIMIT_PERCENT;
sensitivity.parameters = parameters;
sensitivity.npcUsd = npcUsd;
sensitivity.deltaNpcUsd = deltaNpcUsd;
sensitivity.deltaNpcPercent = deltaNpcPercent;
sensitivity.actualValue = actualValue;
sensitivity.lolp = lolp;
sensitivity.feasible = feasible;
sensitivity.resultsTable = resultsTable;
sensitivity.summaryTable = summaryTable;
sensitivity.elapsedSeconds = elapsedSeconds;

save(matFile, 'sensitivity', '-v7.3');
writetable(resultsTable, csvFile);
writetable(summaryTable, summaryCsvFile);

% Save each page as its own high-resolution PNG and combine all pages into
% one multipage PDF. Delete an old PDF first so repeated runs do not append
% new pages to a previous result.
if exist(pdfFile, 'file')
    delete(pdfFile);
end

pngFiles = cell(numel(figureHandles),1);
for pageIndex = 1:numel(figureHandles)
    pngFiles{pageIndex} = fullfile(outputFolder, ...
        sprintf('fixedDesignCostSensitivity_page%d.png', pageIndex));

    try
        exportgraphics(figureHandles(pageIndex), pngFiles{pageIndex}, 'Resolution', 300);
    catch
        print(figureHandles(pageIndex), pngFiles{pageIndex}, '-dpng', '-r300');
    end

    try
        if pageIndex == 1
            exportgraphics(figureHandles(pageIndex), pdfFile, 'ContentType', 'vector');
        else
            exportgraphics(figureHandles(pageIndex), pdfFile, ...
                'ContentType', 'vector', 'Append', true);
        end
    catch
        fprintf('  Could not export page %d to the multipage PDF. PNG was saved.\n', pageIndex);
    end
end

%% ------------------------------------------------------------- print verdict
fprintf('\n==============================================================\n');
fprintf('  SUMMARY — FIXED-DESIGN NPC ROBUSTNESS\n');
fprintf('==============================================================\n');
fprintf('  Base NPC: $%.3f million\n', baseNpcUsd/1e6);
fprintf('  Rule: max |Delta NPC| <= %.2f%% across -20%% ... +20%%\n\n', ...
    ROBUSTNESS_LIMIT_PERCENT);

for p = 1:nParam
    verdict = 'NO';
    if baseDesignHolds(p); verdict = 'YES'; end
    fprintf('  %-25s max |Delta NPC| = %7.4f%%  -> holds: %s\n', ...
        parameters(p).name, maxAbsoluteNpcChangePercent(p), verdict);
end

fprintf('\n  Saved:\n');
fprintf('    %s\n', matFile);
fprintf('    %s\n', csvFile);
fprintf('    %s\n', summaryCsvFile);
for pageIndex = 1:numel(pngFiles)
    fprintf('    %s\n', pngFiles{pageIndex});
end
fprintf('    %s\n', pdfFile);
fprintf('  Runtime: %.1f s\n\n', elapsedSeconds);

end

%% ========================================================================
function p = makeParameter(name, field, unit, group, baseDisplayValue)
p.name = name;
p.field = field;
p.unit = unit;
p.group = group;
p.baseDisplayValue = baseDisplayValue;
end

%% ========================================================================
function [P, displayValue] = applyParameterMultiplier(P, fieldName, multiplier)
% Returns displayValue in the unit shown on the figure/table.
switch fieldName
    case 'photovoltaicCapitalCostUsdPerKilowattPeak'
        P.costs.photovoltaicCapitalCostUsdPerKilowattPeak = ...
            P.costs.photovoltaicCapitalCostUsdPerKilowattPeak * multiplier;
        displayValue = P.costs.photovoltaicCapitalCostUsdPerKilowattPeak;

    case 'batteryEnergyCapitalCostUsdPerKilowattHour'
        P.costs.batteryEnergyCapitalCostUsdPerKilowattHour = ...
            P.costs.batteryEnergyCapitalCostUsdPerKilowattHour * multiplier;
        displayValue = P.costs.batteryEnergyCapitalCostUsdPerKilowattHour;

    case 'dieselGeneratorCapitalCostUsdPerKilowatt'
        P.costs.dieselGeneratorCapitalCostUsdPerKilowatt = ...
            P.costs.dieselGeneratorCapitalCostUsdPerKilowatt * multiplier;
        displayValue = P.costs.dieselGeneratorCapitalCostUsdPerKilowatt;

    case 'landPurchaseCostUsdPerAcre'
        P.costs.landPurchaseCostUsdPerAcre = ...
            P.costs.landPurchaseCostUsdPerAcre * multiplier;
        displayValue = P.costs.landPurchaseCostUsdPerAcre;

    case 'dieselFuelPriceBdtPerLitre'
        P.costs.dieselFuelPriceBdtPerLitre = ...
            P.costs.dieselFuelPriceBdtPerLitre * multiplier;
        displayValue = P.costs.dieselFuelPriceBdtPerLitre;

    case 'importTariffBdtPerKilowattHour'
        P.tariff.importTariffBdtPerKilowattHour = ...
            P.tariff.importTariffBdtPerKilowattHour * multiplier;
        displayValue = P.tariff.importTariffBdtPerKilowattHour;

    case 'realDiscountRateFraction'
        P.costs.realDiscountRateFraction = ...
            P.costs.realDiscountRateFraction * multiplier;
        displayValue = 100 * P.costs.realDiscountRateFraction;

    otherwise
        error('Unknown sensitivity parameter: %s', fieldName);
end
end

%% ========================================================================
function plotSingleParameterPanel(ax, variationPercent, y, parameter, robustnessLimit)
axes(ax); %#ok<LAXES>
hold(ax, 'on');

lineHandle = plot(ax, variationPercent, y, '-o', ...
    'LineWidth', 1.8, 'MarkerSize', 6);

% Label EVERY point with its exact change in NPC from the base value.
% The label is the plotted quantity itself, in percent.
ySpan = max(y) - min(y);
if ySpan < 0.05
    ySpan = 0.05;
end
verticalOffset = 0.035 * ySpan;

for i = 1:numel(variationPercent)
    if y(i) >= 0
        labelY = y(i) + verticalOffset;
        verticalAlignment = 'bottom';
    else
        labelY = y(i) - verticalOffset;
        verticalAlignment = 'top';
    end

    text(ax, variationPercent(i), labelY, sprintf('%+.3f%%', y(i)), ...
        'FontSize', 8, ...
        'HorizontalAlignment', 'center', ...
        'VerticalAlignment', verticalAlignment, ...
        'Color', lineHandle.Color, ...
        'Clipping', 'on');
end

xline(ax, 0, ':', 'Base', 'HandleVisibility','off');
yline(ax, 0, 'k-', 'LineWidth', 0.8, 'HandleVisibility','off');
yline(ax, robustnessLimit, '--', sprintf('+%.0f%%', robustnessLimit), ...
    'HandleVisibility','off', 'LabelHorizontalAlignment','left');
yline(ax, -robustnessLimit, '--', sprintf('-%.0f%%', robustnessLimit), ...
    'HandleVisibility','off', 'LabelHorizontalAlignment','left');

grid(ax, 'on');
box(ax, 'on');
ax.XTick = variationPercent;
xlim(ax, [min(variationPercent)-1.5, max(variationPercent)+1.5]);
xlabel(ax, 'Change in parameter from base value (%)');
ylabel(ax, 'Change in NPC from base value (%)');

% Per user request, title contains only parameter name and changing range.
title(ax, sprintf('%s (+/-20%%)', parameter.name), 'FontWeight','normal');
end

%% ========================================================================
function txt = formatParameterValue(value, unit)
switch unit
    case 'USD/acre'
        txt = sprintf('$%.0f/acre', value);
    case 'USD/kWp'
        txt = sprintf('$%.2f/kWp', value);
    case 'USD/kWh'
        txt = sprintf('$%.2f/kWh', value);
    case 'USD/kW'
        txt = sprintf('$%.2f/kW', value);
    case 'BDT/L'
        txt = sprintf('%.2f BDT/L', value);
    case 'BDT/kWh'
        txt = sprintf('%.3f BDT/kWh', value);
    case '%'
        txt = sprintf('%.3f%%', value);
    otherwise
        txt = sprintf('%.6g %s', value, unit);
end
end

%% ========================================================================
function setupPaths()
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'config'));
addpath(fullfile(here, 'components'));
addpath(fullfile(here, 'dispatch'));
addpath(fullfile(here, 'optimizer'));
end
