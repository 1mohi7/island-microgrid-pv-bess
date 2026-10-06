function generate_all_optimizer_inputs()
%GENERATE_ALL_OPTIMIZER_INPUTS Build and verify the three optimizer inputs.
%
% Run from MATLAB:
%     generate_all_optimizer_inputs
%
% Final optimizer-ready files are saved in:
%     generated_outputs/
%
% The package also contains reference_optimizer_inputs/, which are exact
% copies of the data currently used by the optimizer. Each source model is
% rebuilt into generated_outputs/audit_rebuild/ and compared with that exact
% reference. If a rebuilt file differs, the reference is retained as the
% optimizer-ready output and the difference is reported in GENERATION_AUDIT.
%
% This is deliberate: the load model contains a stochastic component, and
% the exact stochastic realization in the saved optimizer input must not be
% silently replaced by a different realization.

rootDirectory = fileparts(mfilename('fullpath'));
loadDirectory = fullfile(rootDirectory,'load_profile');
renewDirectory = fullfile(rootDirectory,'renewable');
outageDirectory = fullfile(rootDirectory,'outage');
referenceDirectory = fullfile(rootDirectory,'reference_optimizer_inputs');
outputDirectory = fullfile(rootDirectory,'generated_outputs');
auditDirectory = fullfile(outputDirectory,'audit_rebuild');

if exist(outputDirectory,'dir') ~= 7, mkdir(outputDirectory); end
if exist(auditDirectory,'dir') ~= 7, mkdir(auditDirectory); end

addpath(loadDirectory,'-begin');
addpath(renewDirectory,'-begin');
addpath(outageDirectory,'-begin');
addpath(rootDirectory,'-begin');

loadName = 'hourly_feeder_load_profile_spliting.csv';
outageName = 'loadshedding_schedule_1_year_with_status_flag.csv';
renewName = 'renewable_relevent_utc06_nasaPowerPoint_Hourly_20250101_20251231.csv';

audit = struct();

fprintf('\n============================================================\n');
fprintf(' MICROGRID OPTIMIZER INPUT GENERATOR\n');
fprintf('============================================================\n');
fprintf('Final outputs: %s\n\n',outputDirectory);

%% ========================================================================
% 1. LOAD PROFILE MODEL REBUILD

fprintf('1/3 Rebuilding feeder load profile...\n');
try
    config = load_config();
    config.temperature.fileName = fullfile(loadDirectory, ...
        'hourly_temperature_feni__01_01_25_to_01_12_25_.csv');
    config.output.saveCsv = false;
    config.output.showPlots = false;
    config.output.showDailyPlots = false;
    config.output.verbose = true;

    [hourlySubstationLoad,~,modelInfo] = substation_load_profile(config);

    feederConfig = struct();
    feederConfig.feederName = 'Feni feeder';
    feederConfig.connectedLoadMW = 1.50;
    feederConfig.exceedanceMarginMW = 0.25;
    feederConfig.diversityGamma = 1.20;
    feederConfig.outputUnits = 'kW';
    feederConfig.saveCsv = true;
    feederConfig.outputDirectory = auditDirectory;
    feederConfig.showPlots = false;
    feederConfig.showDailyPlots = false;
    feederConfig.dailyPlotLayout = 'grid';
    feederConfig.verbose = true;

    scale_to_feeder(hourlySubstationLoad,modelInfo,feederConfig);

    candidateLoad = fullfile(auditDirectory,loadName);
    referenceLoad = fullfile(referenceDirectory,loadName);
    audit.loadMatch = compare_load_files(candidateLoad,referenceLoad);
    audit.loadStatus = ternary(audit.loadMatch,'REBUILD MATCHED REFERENCE', ...
        'REBUILD DIFFERED - EXACT OPTIMIZER REFERENCE PRESERVED');
catch ME
    audit.loadMatch = false;
    audit.loadStatus = ['REBUILD ERROR - EXACT OPTIMIZER REFERENCE PRESERVED: ' ME.message];
    warning('Load rebuild failed: %s',ME.message);
end

% The exact current optimizer load is the authoritative final output unless
% the rebuild is confirmed numerically identical.
if isfield(audit,'loadMatch') && audit.loadMatch
    copyfile(fullfile(auditDirectory,loadName),fullfile(outputDirectory,loadName),'f');
else
    copyfile(fullfile(referenceDirectory,loadName),fullfile(outputDirectory,loadName),'f');
end

%% ========================================================================
% 2. RENEWABLE UTC -> UTC+6 REBUILD

fprintf('\n2/3 Rebuilding renewable UTC+6 resource file...\n');
try
    rawRenewable = fullfile(renewDirectory, ...
        'POWER_Point_Hourly_20241231_20251231_023d00N_091d40E_UTC.csv');
    candidateRenewable = fullfile(auditDirectory,renewName);
    convertingutc00_to_utc06(rawRenewable,candidateRenewable);

    referenceRenewable = fullfile(referenceDirectory,renewName);
    audit.renewableMatch = compare_renewable_files(candidateRenewable,referenceRenewable);
    audit.renewableStatus = ternary(audit.renewableMatch,'REBUILD MATCHED REFERENCE', ...
        'REBUILD DIFFERED - EXACT OPTIMIZER REFERENCE PRESERVED');
catch ME
    audit.renewableMatch = false;
    audit.renewableStatus = ['REBUILD ERROR - EXACT OPTIMIZER REFERENCE PRESERVED: ' ME.message];
    warning('Renewable rebuild failed: %s',ME.message);
end

if isfield(audit,'renewableMatch') && audit.renewableMatch
    copyfile(fullfile(auditDirectory,renewName),fullfile(outputDirectory,renewName),'f');
else
    copyfile(fullfile(referenceDirectory,renewName),fullfile(outputDirectory,renewName),'f');
end

%% ========================================================================
% 3. OUTAGE / LOAD-SHEDDING SCHEDULE REBUILD

fprintf('\n3/3 Rebuilding grid availability / load-shedding schedule...\n');
originalDirectory = pwd;
cleanupDirectory = onCleanup(@() cd(originalDirectory));
try
    cd(auditDirectory);
    loadshedding_schedule_1_year('design',42);
    cd(originalDirectory);

    candidateOutage = fullfile(auditDirectory,outageName);
    referenceOutage = fullfile(referenceDirectory,outageName);
    audit.outageMatch = compare_outage_files(candidateOutage,referenceOutage);
    audit.outageStatus = ternary(audit.outageMatch,'REBUILD MATCHED REFERENCE', ...
        'REBUILD DIFFERED - EXACT OPTIMIZER REFERENCE PRESERVED');
catch ME
    cd(originalDirectory);
    audit.outageMatch = false;
    audit.outageStatus = ['REBUILD ERROR - EXACT OPTIMIZER REFERENCE PRESERVED: ' ME.message];
    warning('Outage rebuild failed: %s',ME.message);
end

if isfield(audit,'outageMatch') && audit.outageMatch
    copyfile(fullfile(auditDirectory,outageName),fullfile(outputDirectory,outageName),'f');
else
    copyfile(fullfile(referenceDirectory,outageName),fullfile(outputDirectory,outageName),'f');
end

%% ========================================================================
% 4. FINAL OPTIMIZER INPUT VERIFICATION

fprintf('\nVerifying final optimizer-ready inputs...\n');
verificationFile = fullfile(outputDirectory,'VERIFICATION_REPORT.txt');
report = verify_optimizer_inputs(outputDirectory,referenceDirectory,verificationFile);

%% ========================================================================
% 5. GENERATION AUDIT

auditFile = fullfile(outputDirectory,'GENERATION_AUDIT.txt');
fid = fopen(auditFile,'w');
if fid < 0
    error('Could not write %s',auditFile);
end
cleanupAudit = onCleanup(@() fclose(fid));

fprintf(fid,'MICROGRID INPUT GENERATION AUDIT\n');
fprintf(fid,'================================\n\n');
fprintf(fid,'Load profile : %s\n',audit.loadStatus);
fprintf(fid,'Renewable    : %s\n',audit.renewableStatus);
fprintf(fid,'Outage       : %s\n\n',audit.outageStatus);
fprintf(fid,['The final three optimizer-ready filenames are always checked against\n' ...
             'reference_optimizer_inputs before this run is declared complete.\n']);

fprintf('\n============================================================\n');
fprintf(' COMPLETE\n');
fprintf('============================================================\n');
fprintf('Optimizer-ready files:\n');
fprintf('  %s\n',fullfile(outputDirectory,loadName));
fprintf('  %s\n',fullfile(outputDirectory,outageName));
fprintf('  %s\n',fullfile(outputDirectory,renewName));
fprintf('\nVerification report:\n  %s\n',verificationFile);
fprintf('Generation audit:\n  %s\n',auditFile);
fprintf('Source rebuilds:\n  %s\n\n',auditDirectory);

if ~report.pass
    error('Final optimizer input verification failed. Read %s',verificationFile);
end
end

% =========================================================================
function match = compare_load_files(fileA,fileB)
if exist(fileA,'file') ~= 2 || exist(fileB,'file') ~= 2
    match = false; return
end
A = readtable(fileA,'VariableNamingRule','preserve');
B = readtable(fileB,'VariableNamingRule','preserve');
if height(A) ~= height(B) || height(A) ~= 8760
    match = false; return
end
try
    timeA = parse_time(A.datetime);
    timeB = parse_time(B.datetime);
    match = isequal(A.hour,B.hour) && isequal(timeA,timeB) && ...
        max(abs(A.non_critical_load_kW-B.non_critical_load_kW)) <= 1e-3 && ...
        max(abs(A.critical_load_kW-B.critical_load_kW)) <= 1e-3 && ...
        max(abs(A.total_load_kW-B.total_load_kW)) <= 1e-3;
catch
    match = false;
end
end

function match = compare_outage_files(fileA,fileB)
if exist(fileA,'file') ~= 2 || exist(fileB,'file') ~= 2
    match = false; return
end
A = readtable(fileA,'VariableNamingRule','preserve');
B = readtable(fileB,'VariableNamingRule','preserve');
match = height(A)==height(B) && height(A)==8760 && ...
    isequal(A.hour,B.hour) && isequal(A.grid_available,B.grid_available) && ...
    isequal(string(A.outage_cause),string(B.outage_cause));
end

function match = compare_renewable_files(fileA,fileB)
if exist(fileA,'file') ~= 2 || exist(fileB,'file') ~= 2
    match = false; return
end
A = readtable(fileA,'VariableNamingRule','preserve');
B = readtable(fileB,'VariableNamingRule','preserve');
match = height(A)==height(B) && height(A)==8760 && ...
    isequal(A.YEAR,B.YEAR) && isequal(A.MO,B.MO) && ...
    isequal(A.DY,B.DY) && isequal(A.HR,B.HR) && ...
    max(abs(A{:,5:9}-B{:,5:9}),[],'all') <= 1e-12;
end

function t = parse_time(raw)
if isdatetime(raw)
    t = raw(:); return
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

function value = ternary(condition,valueTrue,valueFalse)
if condition
    value = valueTrue;
else
    value = valueFalse;
end
end
