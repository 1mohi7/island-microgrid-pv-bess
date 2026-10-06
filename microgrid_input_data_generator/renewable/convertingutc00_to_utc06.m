function outputTable = convertingutc00_to_utc06(inputFile, outputFile)
%CONVERTINGUTC00_TO_UTC06 Convert NASA POWER hourly UTC data to UTC+6 labels.
%
%   convertingutc00_to_utc06()
%   convertingutc00_to_utc06(inputFile, outputFile)
%   T = convertingutc00_to_utc06(...)
%
% Defaults:
%   input  POWER_Point_Hourly_20241231_20251231_023d00N_091d40E_UTC.csv
%   output renewable_relevent_utc06_nasaPowerPoint_Hourly_20250101_20251231.csv
%
% The raw file contains enough hours around 2025 that shifting each UTC
% timestamp by +6 hours and then selecting local calendar year 2025 yields
% exactly 8760 Bangladesh-local hourly records.

if nargin < 1 || isempty(inputFile)
    inputFile = 'POWER_Point_Hourly_20241231_20251231_023d00N_091d40E_UTC.csv';
end
if nargin < 2 || isempty(outputFile)
    outputFile = 'renewable_relevent_utc06_nasaPowerPoint_Hourly_20250101_20251231.csv';
end

if exist(inputFile,'file') ~= 2
    error('Input NASA POWER file not found: %s', inputFile);
end

% Find the YEAR,MO,... header. NASA POWER adds a text preamble above it.
headerLineCount = find_nasa_header(inputFile);
raw = readmatrix(inputFile,'NumHeaderLines',headerLineCount);

if size(raw,2) < 9
    error('Expected at least 9 numeric columns in NASA POWER hourly file.');
end

variableNames = {'YEAR','MO','DY','HR', ...
    'ALLSKY_SFC_SW_DWN','ALLSKY_SFC_SW_DNI','ALLSKY_SFC_SW_DIFF','T2M','WS10M'};

raw = raw(:,1:9);
T = array2table(raw,'VariableNames',variableNames);

% Use clock labels without attaching a time zone. The source labels are UTC;
% Bangladesh Standard Time is UTC+6, so adding six hours gives local labels.
timeUtcClock = datetime(T.YEAR,T.MO,T.DY,T.HR,0,0);
timeLocal    = timeUtcClock + hours(6);

% Keep exactly local calendar year 2025.
keep = year(timeLocal) == 2025;
T = T(keep,:);
timeLocal = timeLocal(keep);

T.YEAR = year(timeLocal);
T.MO   = month(timeLocal);
T.DY   = day(timeLocal);
T.HR   = hour(timeLocal);

if height(T) ~= 8760
    error('UTC+6 conversion produced %d records; expected 8760.',height(T));
end

expectedStart = datetime(2025,1,1,0,0,0);
expectedEnd   = datetime(2025,12,31,23,0,0);
if timeLocal(1) ~= expectedStart || timeLocal(end) ~= expectedEnd
    error('Converted local timestamps do not span 01-Jan-2025 00:00 to 31-Dec-2025 23:00.');
end
if any(diff(timeLocal) ~= hours(1))
    error('Converted renewable timestamps are not continuous hourly records.');
end

% No NASA missing-value sentinel is allowed into the optimizer input.
numericData = T{:,:};
if any(numericData(:) <= -998.5)
    error('Converted renewable data contains NASA missing-value sentinel(s).');
end

outputDirectory = fileparts(outputFile);
if ~isempty(outputDirectory) && exist(outputDirectory,'dir') ~= 7
    mkdir(outputDirectory);
end
writetable(T,outputFile);

fprintf('\nRenewable UTC -> UTC+6 conversion complete.\n');
fprintf('  input : %s\n',inputFile);
fprintf('  output: %s\n',outputFile);
fprintf('  rows  : %d\n',height(T));
fprintf('  first : %s\n',datestr(timeLocal(1),'dd-mmm-yyyy HH:MM'));
fprintf('  last  : %s\n\n',datestr(timeLocal(end),'dd-mmm-yyyy HH:MM'));

if nargout > 0
    outputTable = T;
end
end

function headerLineCount = find_nasa_header(fileName)
fileId = fopen(fileName,'r');
if fileId < 0
    error('Cannot open %s',fileName);
end
cleanup = onCleanup(@() fclose(fileId));
headerLineCount = 0;
while true
    currentLine = fgetl(fileId);
    if ~ischar(currentLine)
        error('Header row starting YEAR,MO was not found in %s.',fileName);
    end
    headerLineCount = headerLineCount + 1;
    if startsWith(strtrim(currentLine),'YEAR,MO')
        break;
    end
end
end
