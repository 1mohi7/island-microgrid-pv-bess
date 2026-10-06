function inputs = loadFeederInputs(dataDirectory, P)
%LOADFEEDERINPUTS  Read and validate the three input files. Fails loudly.
%
%   inputs = loadFeederInputs(dataDirectory, P)
%
%   Expected files, all 8760 rows, all indexed on the same hour of 2025:
%     hourly_feeder_load_profile_spliting.csv
%         datetime, hour, non_critical_load_kW, critical_load_kW, total_load_kW
%     loadshedding_schedule_1_year_with_status_flag.csv
%         hour, grid_available (1/0), outage_cause
%         (none / shedding / fault / maintenance -- NOTE four causes, not three)
%     renewable_relevent_utc06_nasaPowerPoint_Hourly_20250101_20251231.csv
%         YEAR, MO, DY, HR, ALLSKY_SFC_SW_DWN, ALLSKY_SFC_SW_DNI,
%         ALLSKY_SFC_SW_DIFF, T2M, WS10M
%
%   TIMEZONE NOTE, verified and NOT to be undone: the solar file is ALREADY in
%   Bangladesh local time (UTC+6). Annual-mean irradiance peaks in the hour-11
%   bin, which is the bin containing true solar noon at 11:54 for 91.4 deg east
%   under a 90 deg east standard meridian. The +6 hour shift described in the
%   original brief must NOT be applied; doing so would move the modelled solar
%   peak to 17:00 and invalidate every downstream result.

hoursPerYear = P.site.hoursPerYear;

loadTable   = readtable(fullfile(dataDirectory, ...
                'hourly_feeder_load_profile_spliting.csv'));
outageTable = readtable(fullfile(dataDirectory, ...
                'loadshedding_schedule_1_year_with_status_flag.csv'));
solarTable  = readtable(fullfile(dataDirectory, ...
                'renewable_relevent_utc06_nasaPowerPoint_Hourly_20250101_20251231.csv'));

% ---------------------------------------------------------------- row counts
checkRowCount(loadTable,   hoursPerYear, 'load profile');
checkRowCount(outageTable, hoursPerYear, 'outage trace');
checkRowCount(solarTable,  hoursPerYear, 'solar resource');

% ---------------------------------------------------------------- timestamps
if isdatetime(loadTable.datetime)
    timestamps = loadTable.datetime;
else
    timestamps = datetime(loadTable.datetime, 'InputFormat', 'MM/dd/yyyy HH:mm');
end
solarTimestamps = datetime(solarTable.YEAR, solarTable.MO, solarTable.DY, ...
                           solarTable.HR, 0, 0);

mismatched = sum(solarTimestamps ~= timestamps);
if mismatched > 0
    error('loadFeederInputs:timestampMismatch', ...
        ['Load and solar files disagree on %d timestamps. They must index the ' ...
         'same hours row for row before any merge.'], mismatched);
end
if any(loadTable.hour ~= outageTable.hour)
    error('loadFeederInputs:hourIndexMismatch', ...
        'Load and outage files disagree on the hour index.');
end

inputs.timestamps          = timestamps;
inputs.monthOfYearByHour   = month(timestamps);       % 1..12
inputs.hourOfDayByHour     = hour(timestamps);        % 0..23

% ---------------------------------------------------------------- load
inputs.totalLoadKilowatts       = loadTable.total_load_kW(:);
inputs.criticalLoadKilowatts    = loadTable.critical_load_kW(:);
inputs.nonCriticalLoadKilowatts = loadTable.non_critical_load_kW(:);

balanceError = max(abs(inputs.criticalLoadKilowatts + ...
                       inputs.nonCriticalLoadKilowatts - ...
                       inputs.totalLoadKilowatts));
if balanceError > 1e-6
    error('loadFeederInputs:loadBalance', ...
        ['Critical plus non-critical load does not sum to total load ' ...
         '(max error %.6f kW).'], balanceError);
end

% ---------------------------------------------------------------- outage
causeNames = {'none', 'shedding', 'fault', 'maintenance'};
causeCodes = [P.cause.none P.cause.shedding P.cause.fault P.cause.maintenance];

rawCause = outageTable.outage_cause;
if ~iscell(rawCause); rawCause = cellstr(rawCause); end
inputs.historicalOutageCauseCodes = zeros(hoursPerYear, 1);
for k = 1:numel(causeNames)
    inputs.historicalOutageCauseCodes(strcmp(rawCause, causeNames{k})) = causeCodes(k);
end
unknown = ~ismember(rawCause, causeNames);
if any(unknown)
    error('loadFeederInputs:unknownCause', ...
        'Unrecognised outage causes: %s', strjoin(unique(rawCause(unknown))', ', '));
end

inputs.historicalGridAvailableFlags = double(outageTable.grid_available(:));

inconsistent = sum((inputs.historicalGridAvailableFlags == 0) ~= ...
                   (inputs.historicalOutageCauseCodes ~= P.cause.none));
if inconsistent > 0
    error('loadFeederInputs:flagCauseMismatch', ...
        ['%d hours have an availability flag inconsistent with the cause tag ' ...
         '(available but caused, or unavailable but tagged none).'], inconsistent);
end

% ---------------------------------------------------------------- solar
inputs.globalHorizontalIrradianceWattsPerSquareMetre  = solarTable.ALLSKY_SFC_SW_DWN(:);
inputs.directNormalIrradianceWattsPerSquareMetre      = solarTable.ALLSKY_SFC_SW_DNI(:);
inputs.diffuseHorizontalIrradianceWattsPerSquareMetre = solarTable.ALLSKY_SFC_SW_DIFF(:);
inputs.ambientTemperatureCelsius                      = solarTable.T2M(:);
inputs.windSpeedMetresPerSecond                       = solarTable.WS10M(:);

% ---------------------------------------------------------------- derived
inputs.annualEnergyKilowattHours = sum(inputs.totalLoadKilowatts);
inputs.peakLoadKilowatts         = max(inputs.totalLoadKilowatts);
inputs.peakCriticalLoadKilowatts = max(inputs.criticalLoadKilowatts);
% Load factor is DERIVED from the profile, never asserted as an input.
inputs.loadFactor = (inputs.annualEnergyKilowattHours / hoursPerYear) / ...
                     inputs.peakLoadKilowatts;

inputs.isPeakHourFlags = double(inputs.hourOfDayByHour >= P.tariff.peakPeriodStartHour & ...
                                inputs.hourOfDayByHour <  P.tariff.peakPeriodEndHour);

% ---------------------------------------------------------------- timezone
inputs.timezoneCheck = verifyTimezoneAlignment(inputs, P);

end

% =====================================================================
function checkRowCount(tbl, expected, name)
if height(tbl) ~= expected
    error('loadFeederInputs:rowCount', ...
        ['%s has %d rows, expected %d. A leap year or a partial pull will ' ...
         'misalign every downstream merge.'], name, height(tbl), expected);
end
end

% =====================================================================
function report = verifyTimezoneAlignment(inputs, P)
%VERIFYTIMEZONEALIGNMENT  Confirm the solar file is in local time. Raises, not warns.
%
%   A silent timezone error is the single most damaging failure mode in this
%   study and it must not be possible to run past it.

meanIrradianceByHour = accumarray(inputs.hourOfDayByHour + 1, ...
        inputs.globalHorizontalIrradianceWattsPerSquareMetre, [24 1]) ./ ...
        accumarray(inputs.hourOfDayByHour + 1, 1, [24 1]);

[~, peakIndex] = max(meanIrradianceByHour);
peakHourBin = peakIndex - 1;

% Local clock time of true solar noon, ignoring the equation of time (worth at
% most 16 minutes and never enough to move the peak a whole bin).
solarNoonLocalHours = 12.0 - (P.site.longitudeDegreesEast - ...
                              P.site.standardMeridianDegreesEast) / 15.0;
expectedPeakBin = floor(solarNoonLocalHours);

if abs(peakHourBin - expectedPeakBin) > 1
    error('loadFeederInputs:timezone', ...
        ['Solar resource peaks in hour bin %d but true solar noon falls at ' ...
         '%.2f local. The file is not in local time. Do NOT proceed until ' ...
         'this is resolved.'], peakHourBin, solarNoonLocalHours);
end

daylight = find(meanIrradianceByHour > 0) - 1;
report.peakIrradianceHourBin        = peakHourBin;
report.expectedPeakHourBin          = expectedPeakBin;
report.trueSolarNoonLocalHours      = solarNoonLocalHours;
report.firstDaylightHour            = min(daylight);
report.lastDaylightHour             = max(daylight);
report.additionalShiftRequiredHours = 0;
end
