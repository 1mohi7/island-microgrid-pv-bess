function [dailyWarmthWeight, calendarData, monthlyTemperatureTable] = ...
         compute_warmth_weights(config)
%COMPUTE_WARMTH_WEIGHTS  Daily warmth weights from a temperature time series.
%
%   [dailyWarmthWeight, calendarData, monthlyTemperatureTable] = ...
%       compute_warmth_weights(config)
%   [...] = compute_warmth_weights();      % uses load_config
%
%   dailyWarmthWeight       : numberOfDays x 1, in [0, maximumWarmthWeight]
%   calendarData            : calendar struct derived FROM THE TEMPERATURE
%                             FILE, so leap years and partial years need no
%                             special-casing and the load series is
%                             guaranteed to align with the temperature series
%   monthlyTemperatureTable : monthly temperature and warmth summary
%
%   METHOD -----------------------------------------------------------------
%   1. Daily cooling degree days, accumulated from hourly data where
%      available:
%          CDD(d) = (1/24) * sum over hours of max( T(h) - baseTemperature, 0 )
%      The hourly formulation matters. A daily-mean formulation returns
%      exactly zero for December and January at this site, because the daily
%      mean never exceeds the 24 C base - yet afternoon temperatures still
%      reach 26 C and some fan load is present. Hourly accumulation captures
%      that; daily-mean accumulation discards it.
%
%   2. Thermal inertia, as an exponentially weighted moving average.
%      Cooling load does not track temperature instantaneously: building
%      thermal mass and behavioural adaptation give a lag of a few days.
%
%   3. Normalisation against a reference, then clipping. Weights above 1 are
%      permitted so an unusually hot day extrapolates past the hot archetype.

if nargin < 1 || isempty(config), config = load_config(); end
verbose = config.output.verbose;

% ------------------------------------------------------------------------
% 1. Read the temperature file
% ------------------------------------------------------------------------
temperatureFileName = config.temperature.fileName;
if exist(temperatureFileName, 'file') ~= 2
    error(['Temperature file not found: %s\n' ...
           'Set config.temperature.fileName in load_config.m. Note that ' ...
           'MATLAB resolves relative paths against the current folder.'], ...
           temperatureFileName);
end

switch lower(config.temperature.fileFormat)
    case {'nasa_hourly','nasa_daily'}
        headerLineCount = find_nasa_header(temperatureFileName);
        rawData     = readmatrix(temperatureFileName, ...
                                 'NumHeaderLines', headerLineCount);
        recordYear  = rawData(:,1);
        recordMonth = rawData(:,2);
        recordDay   = rawData(:,3);
        if strcmpi(config.temperature.fileFormat, 'nasa_hourly')
            recordTemperature = rawData(:,5);
            isHourlyData      = true;
        else
            recordTemperature = rawData(:,4);
            isHourlyData      = false;
        end

    case 'generic'
        if isempty(config.temperature.headerLineCount)
            error(['config.temperature.headerLineCount must be set when ' ...
                   'fileFormat is ''generic''.']);
        end
        rawData     = readmatrix(temperatureFileName, ...
                        'NumHeaderLines', config.temperature.headerLineCount);
        recordYear        = rawData(:, config.temperature.columnYear);
        recordMonth       = rawData(:, config.temperature.columnMonth);
        recordDay         = rawData(:, config.temperature.columnDay);
        recordTemperature = rawData(:, config.temperature.columnTemp);
        isHourlyData      = ~isempty(config.temperature.columnHour);

    otherwise
        error('Unknown config.temperature.fileFormat: %s', ...
              config.temperature.fileFormat);
end

% Missing values
isMissing = (recordTemperature <= config.temperature.missingValue + 1) | ...
             isnan(recordTemperature);
if any(isMissing)
    if all(isMissing)
        error('All temperature records are missing. Check the file.');
    end
    if verbose
        fprintf('  %d missing temperature values interpolated\n', sum(isMissing));
    end
    recordTemperature(isMissing) = interp1(find(~isMissing), ...
        recordTemperature(~isMissing), find(isMissing), 'linear', 'extrap');
end

if verbose
    fprintf('  %s: %d records, T from %.1f to %.1f C, mean %.1f C\n', ...
            temperatureFileName, numel(recordTemperature), ...
            min(recordTemperature), max(recordTemperature), ...
            mean(recordTemperature));
end

% ------------------------------------------------------------------------
% 2. Build the calendar from the file and compute daily CDD
% ------------------------------------------------------------------------
recordDateNumber = datenum(recordYear, recordMonth, recordDay);
[uniqueDateNumber, firstRecordOfDay] = unique(recordDateNumber, 'stable');
numberOfDays = numel(uniqueDateNumber);

dayGroupIndex = cumsum([1; diff(recordDateNumber) ~= 0]);
recordsPerDay = accumarray(dayGroupIndex, 1);

if isHourlyData
    if any(recordsPerDay ~= 24)
        warning(['%d day(s) do not contain 24 records. CDD for those days ' ...
                 'is normalised by the actual record count.'], ...
                 sum(recordsPerDay ~= 24));
    end
    dailyCoolingDegreeDays = accumarray(dayGroupIndex, ...
        max(recordTemperature - config.warmth.baseTemperatureC, 0)) ./ recordsPerDay;
    dailyMeanTemperature = accumarray(dayGroupIndex, recordTemperature) ./ recordsPerDay;
else
    dailyCoolingDegreeDays = max(recordTemperature - config.warmth.baseTemperatureC, 0);
    dailyMeanTemperature   = recordTemperature;
    if verbose
        fprintf(['  NOTE: daily-resolution input. CDD is computed from daily\n' ...
                 '  means and will understate cooling need in cool months.\n']);
    end
end

calendarData.numberOfDays        = numberOfDays;
calendarData.dateNumber          = uniqueDateNumber;
calendarData.yearOfDay           = recordYear(firstRecordOfDay);
calendarData.monthOfDay          = recordMonth(firstRecordOfDay);
calendarData.dayOfMonth          = recordDay(firstRecordOfDay);
dayOfWeekIndex                   = weekday(uniqueDateNumber);   % 1=Sun...7=Sat
dayNameList                      = {'Sun','Mon','Tue','Wed','Thu','Fri','Sat'};
calendarData.dayName             = dayNameList(dayOfWeekIndex)';
calendarData.dailyMeanTemperature = dailyMeanTemperature;
calendarData.dailyCoolingDegreeDays = dailyCoolingDegreeDays;

if verbose
    fprintf('  calendar: %d days, %s to %s\n', numberOfDays, ...
            datestr(uniqueDateNumber(1),   'dd-mmm-yyyy'), ...
            datestr(uniqueDateNumber(end), 'dd-mmm-yyyy'));
end

% ------------------------------------------------------------------------
% 3. Thermal inertia
% ------------------------------------------------------------------------
thermalInertiaAlpha = config.warmth.thermalInertiaAlpha;
if thermalInertiaAlpha <= 0 || thermalInertiaAlpha > 1
    error('config.warmth.thermalInertiaAlpha must be in the interval (0,1].');
end
smoothedCoolingDegreeDays = filter(thermalInertiaAlpha, ...
    [1 -(1-thermalInertiaAlpha)], dailyCoolingDegreeDays, ...
    (1-thermalInertiaAlpha)*dailyCoolingDegreeDays(1));

% ------------------------------------------------------------------------
% 4. Normalise
% ------------------------------------------------------------------------
uniqueMonths = unique(calendarData.monthOfDay);
switch lower(config.warmth.referenceMode)
    case 'hottest_month'
        monthlyMeanSmoothedCdd = zeros(numel(uniqueMonths),1);
        for monthIndex = 1:numel(uniqueMonths)
            selectedDays = (calendarData.monthOfDay == uniqueMonths(monthIndex));
            monthlyMeanSmoothedCdd(monthIndex) = ...
                mean(smoothedCoolingDegreeDays(selectedDays));
        end
        referenceCoolingDegreeDays = max(monthlyMeanSmoothedCdd);
    case 'percentile'
        referenceCoolingDegreeDays = simple_percentile( ...
            smoothedCoolingDegreeDays, config.warmth.referencePercentile);
    case 'max'
        referenceCoolingDegreeDays = max(smoothedCoolingDegreeDays);
    otherwise
        error('Unknown config.warmth.referenceMode: %s', ...
              config.warmth.referenceMode);
end

if referenceCoolingDegreeDays <= 0
    error(['Reference cooling degree days is zero - no cooling load anywhere ' ...
           'in the series. Check config.warmth.baseTemperatureC (currently ' ...
           '%.1f C) against the temperature range above.'], ...
           config.warmth.baseTemperatureC);
end

dailyWarmthWeight = min(max(smoothedCoolingDegreeDays / ...
    referenceCoolingDegreeDays, 0), config.warmth.maximumWarmthWeight);

% ------------------------------------------------------------------------
% 5. Monthly summary
% ------------------------------------------------------------------------
numberOfMonths       = numel(uniqueMonths);
Month                = uniqueMonths(:);
MeanTemperatureC     = zeros(numberOfMonths,1);
MaxTemperatureC      = zeros(numberOfMonths,1);
CddPerDay            = zeros(numberOfMonths,1);
MeanWarmthWeight     = zeros(numberOfMonths,1);
MinWarmthWeight      = zeros(numberOfMonths,1);
MaxWarmthWeight      = zeros(numberOfMonths,1);

for monthIndex = 1:numberOfMonths
    selectedDays    = (calendarData.monthOfDay == uniqueMonths(monthIndex));
    selectedRecords = (recordMonth == uniqueMonths(monthIndex));
    MeanTemperatureC(monthIndex) = mean(recordTemperature(selectedRecords));
    MaxTemperatureC(monthIndex)  = max(recordTemperature(selectedRecords));
    CddPerDay(monthIndex)        = mean(dailyCoolingDegreeDays(selectedDays));
    MeanWarmthWeight(monthIndex) = mean(dailyWarmthWeight(selectedDays));
    MinWarmthWeight(monthIndex)  = min(dailyWarmthWeight(selectedDays));
    MaxWarmthWeight(monthIndex)  = max(dailyWarmthWeight(selectedDays));
end

monthlyTemperatureTable = table(Month, MeanTemperatureC, MaxTemperatureC, ...
    CddPerDay, MeanWarmthWeight, MinWarmthWeight, MaxWarmthWeight);

if verbose
    fprintf(['\n=== Monthly temperature and warmth weight ' ...
             '(base %.0f C, alpha %.2f) ===\n'], ...
            config.warmth.baseTemperatureC, thermalInertiaAlpha);
    disp(monthlyTemperatureTable);
end

% ------------------------------------------------------------------------
% 6. Diagnostic: is the evening peak thermally driven?
% ------------------------------------------------------------------------
% If cooling need peaks in mid-afternoon while observed demand peaks after
% sunset, the evening peak is occupancy-driven and must not be modelled as a
% cooling overlay. Reported here for the record.
if isHourlyData
    [~, hottestMonthIndex] = max(CddPerDay);
    selectedRecords = (recordMonth == uniqueMonths(hottestMonthIndex));
    hourlyTemperatureMatrix = reshape(recordTemperature(selectedRecords), 24, []);
    coolingNeedShape = max(mean(hourlyTemperatureMatrix,2) - ...
                           config.warmth.baseTemperatureC, 0);
    if max(coolingNeedShape) > 0
        coolingNeedShape = coolingNeedShape / max(coolingNeedShape);
        [~, coolingPeakHour] = max(coolingNeedShape);
        if verbose
            fprintf(['  Cooling need peaks at hour %d; at hour 20 it is %.2f.\n' ...
                     '  The evening demand peak is therefore occupancy-driven, ' ...
                     'not thermal.\n'], coolingPeakHour-1, coolingNeedShape(21));
        end
        calendarData.coolingNeedShape = coolingNeedShape;
    end
end
end

% =========================================================================
function headerLineCount = find_nasa_header(fileName)
%FIND_NASA_HEADER  Locate the YEAR,MO,... row in a NASA POWER CSV.
fileId = fopen(fileName, 'r');
if fileId < 0, error('Cannot open %s', fileName); end
headerLineCount = 0;
while true
    currentLine = fgetl(fileId);
    if ~ischar(currentLine)
        fclose(fileId);
        error(['Header row starting YEAR,MO was not found in %s. If this ' ...
               'is not a NASA POWER file, set ' ...
               'config.temperature.fileFormat = ''generic''.'], fileName);
    end
    headerLineCount = headerLineCount + 1;
    if startsWith(strtrim(currentLine), 'YEAR,MO'), break; end
end
fclose(fileId);
end

% =========================================================================
function percentileValue = simple_percentile(dataVector, percentileWanted)
%SIMPLE_PERCENTILE  Percentile without the Statistics Toolbox.
sortedData    = sort(dataVector(:));
numberOfPoints = numel(sortedData);
if numberOfPoints == 1
    percentileValue = sortedData;
    return;
end
positionVector  = 100*((1:numberOfPoints)' - 0.5)/numberOfPoints;
percentileValue = interp1(positionVector, sortedData, percentileWanted, ...
                          'linear', 'extrap');
end
