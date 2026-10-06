function report = verify_optimizer_inputs(dataDirectory, referenceDirectory, reportFile)
%VERIFY_OPTIMIZER_INPUTS Validate the three optimizer input CSV files.
%
%   report = verify_optimizer_inputs(dataDirectory)
%   report = verify_optimizer_inputs(dataDirectory, referenceDirectory)
%   report = verify_optimizer_inputs(dataDirectory, referenceDirectory, reportFile)
%
% Checks schema, 8760-hour alignment, load balance, outage flag/cause
% consistency, renewable missing values, and (when a reference directory is
% supplied) equality with the exact input files used by the optimizer.

if nargin < 1 || isempty(dataDirectory)
    dataDirectory = fullfile(fileparts(mfilename('fullpath')),'generated_outputs');
end
if nargin < 2
    referenceDirectory = '';
end
if nargin < 3 || isempty(reportFile)
    reportFile = fullfile(dataDirectory,'VERIFICATION_REPORT.txt');
end

loadName = 'hourly_feeder_load_profile_spliting.csv';
outageName = 'loadshedding_schedule_1_year_with_status_flag.csv';
renewName = 'renewable_relevent_utc06_nasaPowerPoint_Hourly_20250101_20251231.csv';

loadFile = fullfile(dataDirectory,loadName);
outageFile = fullfile(dataDirectory,outageName);
renewFile = fullfile(dataDirectory,renewName);

required = {loadFile,outageFile,renewFile};
for k = 1:numel(required)
    if exist(required{k},'file') ~= 2
        error('Missing required optimizer input: %s',required{k});
    end
end

L = readtable(loadFile,'VariableNamingRule','preserve');
O = readtable(outageFile,'VariableNamingRule','preserve');
R = readtable(renewFile,'VariableNamingRule','preserve');

expectedLoad = {'datetime','hour','non_critical_load_kW','critical_load_kW','total_load_kW'};
expectedOutage = {'hour','grid_available','outage_cause'};
expectedRenew = {'YEAR','MO','DY','HR','ALLSKY_SFC_SW_DWN','ALLSKY_SFC_SW_DNI', ...
                 'ALLSKY_SFC_SW_DIFF','T2M','WS10M'};

issues = {};
notes = {};

if ~isequal(L.Properties.VariableNames,expectedLoad)
    issues{end+1} = sprintf('Load columns differ from expected schema: %s', ...
        strjoin(L.Properties.VariableNames,', ')); %#ok<AGROW>
end
if ~isequal(O.Properties.VariableNames,expectedOutage)
    issues{end+1} = sprintf('Outage columns differ from expected schema: %s', ...
        strjoin(O.Properties.VariableNames,', ')); %#ok<AGROW>
end
if ~isequal(R.Properties.VariableNames,expectedRenew)
    issues{end+1} = sprintf('Renewable columns differ from expected schema: %s', ...
        strjoin(R.Properties.VariableNames,', ')); %#ok<AGROW>
end

if height(L) ~= 8760, issues{end+1} = sprintf('Load rows = %d, expected 8760.',height(L)); end %#ok<AGROW>
if height(O) ~= 8760, issues{end+1} = sprintf('Outage rows = %d, expected 8760.',height(O)); end %#ok<AGROW>
if height(R) ~= 8760, issues{end+1} = sprintf('Renewable rows = %d, expected 8760.',height(R)); end %#ok<AGROW>

% Continue only when enough rows are present for the checks below.
if height(L) == 8760
    if any(L.hour(:) ~= (1:8760)')
        issues{end+1} = 'Load hour index is not exactly 1:8760.'; %#ok<AGROW>
    end
    loadTime = parse_load_time(L.datetime);
    expectedTime = (datetime(2025,1,1,0,0,0):hours(1):datetime(2025,12,31,23,0,0))';
    if numel(loadTime) ~= 8760 || any(loadTime ~= expectedTime)
        issues{end+1} = 'Load timestamps are not the continuous 2025 local-hour sequence.'; %#ok<AGROW>
    end

    loadValues = [L.non_critical_load_kW L.critical_load_kW L.total_load_kW];
    if any(~isfinite(loadValues),'all')
        issues{end+1} = 'Load file contains NaN or Inf.'; %#ok<AGROW>
    end
    if any(loadValues < -1e-9,'all')
        issues{end+1} = 'Load file contains negative demand.'; %#ok<AGROW>
    end
    balanceError = max(abs(L.non_critical_load_kW + L.critical_load_kW - L.total_load_kW));
    if balanceError > 1e-6
        issues{end+1} = sprintf('Load balance error = %.9g kW.',balanceError); %#ok<AGROW>
    end
else
    loadTime = datetime.empty(0,1);
    balanceError = NaN;
end

if height(O) == 8760
    if any(O.hour(:) ~= (1:8760)')
        issues{end+1} = 'Outage hour index is not exactly 1:8760.'; %#ok<AGROW>
    end
    if any(~ismember(O.grid_available,[0 1]))
        issues{end+1} = 'grid_available contains values other than 0 or 1.'; %#ok<AGROW>
    end
    causeText = string(O.outage_cause);
    allowed = ["none","shedding","maintenance","fault"];
    if any(~ismember(causeText,allowed))
        issues{end+1} = sprintf('Unknown outage cause(s): %s', ...
            strjoin(unique(causeText(~ismember(causeText,allowed))),', ')); %#ok<AGROW>
    end
    inconsistency = sum((O.grid_available == 0) ~= (causeText ~= "none"));
    if inconsistency > 0
        issues{end+1} = sprintf('%d outage rows have inconsistent flag and cause.',inconsistency); %#ok<AGROW>
    end
else
    causeText = strings(0,1);
    inconsistency = NaN;
end

if height(R) == 8760
    renewTime = datetime(R.YEAR,R.MO,R.DY,R.HR,0,0);
    expectedTime = (datetime(2025,1,1,0,0,0):hours(1):datetime(2025,12,31,23,0,0))';
    if any(renewTime ~= expectedTime)
        issues{end+1} = 'Renewable timestamps are not the continuous 2025 UTC+6 sequence.'; %#ok<AGROW>
    end
    if ~isempty(loadTime) && any(renewTime ~= loadTime)
        issues{end+1} = 'Load and renewable timestamps are not aligned row-for-row.'; %#ok<AGROW>
    end
    renewValues = R{:,5:9};
    if any(~isfinite(renewValues),'all')
        issues{end+1} = 'Renewable file contains NaN or Inf.'; %#ok<AGROW>
    end
    if any(renewValues <= -998.5,'all')
        issues{end+1} = 'Renewable file contains NASA missing-value sentinel(s).'; %#ok<AGROW>
    end
end

% Reference comparison: this is the exact data currently used by the optimizer.
referencePass = NaN;
referenceMessage = 'Reference comparison not requested.';
if ~isempty(referenceDirectory)
    referencePass = true;
    refLoadFile = fullfile(referenceDirectory,loadName);
    refOutageFile = fullfile(referenceDirectory,outageName);
    refRenewFile = fullfile(referenceDirectory,renewName);
    if all(cellfun(@(f) exist(f,'file') == 2,{refLoadFile,refOutageFile,refRenewFile}))
        RL = readtable(refLoadFile,'VariableNamingRule','preserve');
        RO = readtable(refOutageFile,'VariableNamingRule','preserve');
        RR = readtable(refRenewFile,'VariableNamingRule','preserve');

        loadReferencePass = height(L)==height(RL) && ...
            isequal(L.hour,RL.hour) && ...
            isequal(parse_load_time(L.datetime),parse_load_time(RL.datetime)) && ...
            max(abs(L.non_critical_load_kW-RL.non_critical_load_kW)) <= 1e-9 && ...
            max(abs(L.critical_load_kW-RL.critical_load_kW)) <= 1e-9 && ...
            max(abs(L.total_load_kW-RL.total_load_kW)) <= 1e-9;

        outageReferencePass = height(O)==height(RO) && isequal(O.hour,RO.hour) && ...
            isequal(O.grid_available,RO.grid_available) && ...
            isequal(string(O.outage_cause),string(RO.outage_cause));

        renewReferencePass = height(R)==height(RR) && ...
            isequal(R.YEAR,RR.YEAR) && isequal(R.MO,RR.MO) && ...
            isequal(R.DY,RR.DY) && isequal(R.HR,RR.HR) && ...
            max(abs(R{:,5:9}-RR{:,5:9}),[],'all') <= 1e-12;

        referencePass = loadReferencePass && outageReferencePass && renewReferencePass;
        referenceMessage = sprintf('load=%s, outage=%s, renewable=%s', ...
            pass_text(loadReferencePass),pass_text(outageReferencePass),pass_text(renewReferencePass));
        if ~referencePass
            issues{end+1} = ['Generated optimizer inputs do not all match the exact ' ...
                'reference inputs: ' referenceMessage]; %#ok<AGROW>
        end
    else
        referencePass = false;
        referenceMessage = 'One or more reference files are missing.';
        issues{end+1} = referenceMessage; %#ok<AGROW>
    end
end

% Metrics used in the verification report.
report = struct();
report.pass = isempty(issues);
report.issues = issues;
report.referencePass = referencePass;
report.referenceMessage = referenceMessage;
report.balanceErrorKW = balanceError;

if height(L)==8760
    report.meanLoadKW = mean(L.total_load_kW);
    report.peakLoadKW = max(L.total_load_kW);
    report.minimumLoadKW = min(L.total_load_kW);
    report.loadFactor = report.meanLoadKW/report.peakLoadKW;
    report.peakCriticalKW = max(L.critical_load_kW);
    report.meanCriticalKW = mean(L.critical_load_kW);
    report.criticalEnergyShare = sum(L.critical_load_kW)/sum(L.total_load_kW);
end
if height(O)==8760
    report.availableHours = sum(O.grid_available==1);
    report.outageHours = sum(O.grid_available==0);
    report.sheddingHours = sum(causeText=="shedding");
    report.maintenanceHours = sum(causeText=="maintenance");
    report.faultHours = sum(causeText=="fault");
end

% Write plain-text report.
reportDirectory = fileparts(reportFile);
if ~isempty(reportDirectory) && exist(reportDirectory,'dir') ~= 7
    mkdir(reportDirectory);
end
fid = fopen(reportFile,'w');
if fid < 0
    error('Could not open verification report for writing: %s',reportFile);
end
cleanup = onCleanup(@() fclose(fid));

fprintf(fid,'MICROGRID OPTIMIZER INPUT VERIFICATION\n');
fprintf(fid,'======================================\n\n');
fprintf(fid,'Data directory: %s\n',dataDirectory);
fprintf(fid,'Overall status: %s\n',pass_text(report.pass));
fprintf(fid,'Reference comparison: %s\n\n',referenceMessage);

if height(L)==8760
    fprintf(fid,'LOAD PROFILE\n');
    fprintf(fid,'  Rows                  : %d\n',height(L));
    fprintf(fid,'  Mean total load       : %.6f kW\n',report.meanLoadKW);
    fprintf(fid,'  Peak total load       : %.6f kW\n',report.peakLoadKW);
    fprintf(fid,'  Minimum total load    : %.6f kW\n',report.minimumLoadKW);
    fprintf(fid,'  Load factor           : %.9f\n',report.loadFactor);
    fprintf(fid,'  Peak critical load    : %.6f kW\n',report.peakCriticalKW);
    fprintf(fid,'  Mean critical load    : %.6f kW\n',report.meanCriticalKW);
    fprintf(fid,'  Critical energy share : %.6f %%\n',100*report.criticalEnergyShare);
    fprintf(fid,'  Max balance error     : %.12g kW\n\n',balanceError);
end

if height(O)==8760
    fprintf(fid,'GRID AVAILABILITY / OUTAGES\n');
    fprintf(fid,'  Available             : %d h\n',report.availableHours);
    fprintf(fid,'  Unavailable total     : %d h\n',report.outageHours);
    fprintf(fid,'  Shedding              : %d h\n',report.sheddingHours);
    fprintf(fid,'  Maintenance           : %d h\n',report.maintenanceHours);
    fprintf(fid,'  Fault                 : %d h\n\n',report.faultHours);
end

if height(R)==8760
    fprintf(fid,'RENEWABLE RESOURCE\n');
    fprintf(fid,'  Rows                  : %d\n',height(R));
    fprintf(fid,'  First local timestamp : 01-Jan-2025 00:00\n');
    fprintf(fid,'  Last local timestamp  : 31-Dec-2025 23:00\n');
    fprintf(fid,'  NASA missing sentinels: none\n\n');
end

if isempty(issues)
    fprintf(fid,'CHECKS: ALL PASSED\n');
else
    fprintf(fid,'ISSUES\n');
    for k = 1:numel(issues)
        fprintf(fid,'  %d. %s\n',k,issues{k});
    end
end

fprintf('\nVerification %s. Report written to:\n%s\n\n',pass_text(report.pass),reportFile);
end

function t = parse_load_time(raw)
if isdatetime(raw)
    t = raw(:);
    return
end
try
    t = datetime(raw,'InputFormat','MM/dd/yyyy HH:mm');
catch
    try
        t = datetime(raw,'InputFormat','yyyy-MM-dd HH:mm');
    catch
        t = datetime(raw);
    end
end
t = t(:);
end

function s = pass_text(tf)
if isnumeric(tf) && isnan(tf)
    s = 'NOT CHECKED';
elseif tf
    s = 'PASS';
else
    s = 'FAIL';
end
end
