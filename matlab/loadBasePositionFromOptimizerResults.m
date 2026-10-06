function basePosition = loadBasePositionFromOptimizerResults(optimizerResultsFile)
%LOADBASEPOSITIONFROMOPTIMIZERRESULTS Load the final outage-aware sizing.
%
%   basePosition = loadBasePositionFromOptimizerResults()
%   basePosition = loadBasePositionFromOptimizerResults(optimizerResultsFile)
%
%   With no input, this function looks for optimizerResults.mat in:
%       1) <this MATLAB folder>/results/optimizerResults.mat
%       2) ./results/optimizerResults.mat
%       3) <this MATLAB folder>/optimizerResults.mat
%
%   It reads results.cells.awareAware.sizing and returns:
%       [PV_kW, BESS_kWh, diesel_kW, inverter_kW]
%
%   The sensitivity sweeps call this automatically when basePosition is not
%   supplied, so regret is always calculated against the latest saved
%   outage-aware optimum instead of a hard-coded sizing vector.

if nargin < 1 || isempty(optimizerResultsFile)
    here = fileparts(mfilename('fullpath'));
    candidates = { ...
        fullfile(here, 'results', 'optimizerResults.mat'), ...
        fullfile('.', 'results', 'optimizerResults.mat'), ...
        fullfile(here, 'optimizerResults.mat')};

    optimizerResultsFile = '';
    for candidateIndex = 1:numel(candidates)
        if exist(candidates{candidateIndex}, 'file') == 2
            optimizerResultsFile = candidates{candidateIndex};
            break;
        end
    end

    if isempty(optimizerResultsFile)
        error('loadBasePositionFromOptimizerResults:FileNotFound', ...
            ['Could not find optimizerResults.mat. Run runOptimizer first, ' ...
             'or place the file in ./results/.']);
    end
elseif exist(optimizerResultsFile, 'file') ~= 2
    error('loadBasePositionFromOptimizerResults:FileNotFound', ...
        'Optimizer result file not found: %s', optimizerResultsFile);
end

loaded = load(optimizerResultsFile);
if ~isfield(loaded, 'results')
    error('loadBasePositionFromOptimizerResults:MissingResults', ...
        'File %s does not contain a variable named results.', optimizerResultsFile);
end

results = loaded.results;
if ~isfield(results, 'cells') || ...
   ~isfield(results.cells, 'awareAware') || ...
   ~isfield(results.cells.awareAware, 'sizing')
    error('loadBasePositionFromOptimizerResults:MissingAwareSizing', ...
        ['File %s does not contain results.cells.awareAware.sizing. ' ...
         'Use an optimizerResults.mat produced by the current runOptimizer.'], ...
        optimizerResultsFile);
end

sizing = results.cells.awareAware.sizing;
requiredFields = { ...
    'photovoltaicCapacityKilowatts', ...
    'batteryEnergyCapacityKilowattHours', ...
    'generatorRatingKilowatts', ...
    'inverterRatingKilowatts'};

for fieldIndex = 1:numel(requiredFields)
    if ~isfield(sizing, requiredFields{fieldIndex})
        error('loadBasePositionFromOptimizerResults:MissingSizingField', ...
            'Aware sizing is missing field: %s', requiredFields{fieldIndex});
    end
end

basePosition = [ ...
    sizing.photovoltaicCapacityKilowatts, ...
    sizing.batteryEnergyCapacityKilowattHours, ...
    sizing.generatorRatingKilowatts, ...
    sizing.inverterRatingKilowatts];

if numel(basePosition) ~= 4 || any(~isfinite(basePosition))
    error('loadBasePositionFromOptimizerResults:InvalidSizing', ...
        'Loaded aware sizing is not a finite 4-element sizing vector.');
end

basePosition = basePosition(:).';

fprintf('  Base design auto-loaded from: %s\n', optimizerResultsFile);
fprintf('  Base design: PV %.0f kW | BESS %.0f kWh | DG %.0f kW | INV %.0f kW\n', ...
    basePosition(1), basePosition(2), basePosition(3), basePosition(4));
end
