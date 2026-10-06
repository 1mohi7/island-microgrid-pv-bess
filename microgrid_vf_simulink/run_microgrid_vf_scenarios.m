function run_microgrid_vf_scenarios()
%RUN_MICROGRID_VF_SCENARIOS Build, run, plot, and export all five simulations.
%
% MATLAB/Simulink R2025b workflow:
%   1) Keep the project folder structure intact:
%          <project>/matlab/results/optimizerResults.mat
%          <project>/microgrid_vf_simulink/run_microgrid_vf_scenarios.m
%   2) Run this function from any MATLAB Current Folder.
%
% The dynamic model reads the optimizer output directly from
% ../matlab/results/optimizerResults.mat. No copied MAT-file is required
% inside microgrid_vf_simulink. Figures and CSV files are written beside
% this runner in microgrid_vf_simulink/vf_results/.

clc;

% Resolve every project path from THIS file, not from MATLAB's Current Folder.
scriptDir = fileparts(mfilename('fullpath'));
projectDir = fileparts(scriptDir);
optimizerResultsFile = fullfile(projectDir,'matlab','results','optimizerResults.mat');

requiredLocal = {'microgrid_vf_sfun.m','build_microgrid_vf_model.m'};
for k = 1:numel(requiredLocal)
    requiredPath = fullfile(scriptDir,requiredLocal{k});
    if ~isfile(requiredPath)
        error('Required Simulink file missing: %s',requiredPath);
    end
end
if ~isfile(optimizerResultsFile)
    error('Optimizer result file missing: %s\nRun matlab/runOptimizer.m first.', ...
        optimizerResultsFile);
end

% Make the S-function and model-builder visible without requiring cd().
addpath(scriptDir);

fprintf('Loading optimizer result directly from:\n  %s\n',optimizerResultsFile);
D = load(optimizerResultsFile,'results');
if ~isfield(D,'results')
    error('The optimizer result file does not contain variable ''results'': %s', ...
        optimizerResultsFile);
end
R = D.results;
P = R.P;  % Use the exact parameter set stored with the optimized design.

sizing = R.cells.awareAware.sizing;
critical = R.inputs.criticalLoadKilowatts(:);
noncritical = R.inputs.nonCriticalLoadKilowatts(:);
pvPerKw = R.photovoltaic.generationPerInstalledKilowatt(:);
pvAvailable = pvPerKw * sizing.photovoltaicCapacityKilowatts;

bessDischargeLimitKW = min( ...
    P.battery.maximumDischargeRatePerHour * sizing.batteryEnergyCapacityKilowattHours, ...
    sizing.inverterRatingKilowatts);
bessChargeLimitKW = min( ...
    P.battery.maximumChargeRatePerHour * sizing.batteryEnergyCapacityKilowattHours, ...
    sizing.inverterRatingKilowatts);

fprintf('\nOptimized aware design used in the dynamic demonstrations:\n');
fprintf('  PV       = %.0f kW\n',sizing.photovoltaicCapacityKilowatts);
fprintf('  BESS     = %.0f kWh\n',sizing.batteryEnergyCapacityKilowattHours);
fprintf('  Inverter = %.0f kW\n',sizing.inverterRatingKilowatts);
fprintf('  Diesel   = %.0f kW\n',sizing.generatorRatingKilowatts);
fprintf('  BESS dispatch power limit (0.5C) = %.1f kW\n\n',bessDischargeLimitKW);

% ---------------------------------------------------------------------
% Shared dynamic assumptions. Values not already in the project inputs are
% intentionally centralized here so they are visible and easy to sensitivity-test.
dyn.sampleTimeS = 1e-3;
dyn.nominalFrequencyHz = 50;
dyn.busVoltageLLRmsV = 400;              % equivalent LV bus, not literal feeder voltage
dyn.loadPowerFactor = P.tariff.assumedPowerFactor;
dyn.powerBaseKW = sizing.inverterRatingKilowatts;

dyn.pfDroopFraction = 0.025;             % 2.5% P-f droop
dyn.qvDroopFraction = 0.025;             % 2.5% Q-V droop
dyn.bessPfDroopGainKWperHz = sizing.inverterRatingKilowatts ...
    / (dyn.pfDroopFraction*dyn.nominalFrequencyHz);
dyn.bessQvDroopGainKvarPerPu = sizing.inverterRatingKilowatts ...
    / dyn.qvDroopFraction;

% Reduced-order response constants. These are demonstration-model assumptions,
% not measured equipment data.
dyn.effectiveInertiaConstantS = 3.0;
dyn.frequencyDampingKWperHz = 10.0;
dyn.bessPowerTimeConstantS = 0.040;
dyn.bessReactiveTimeConstantS = 0.030;
dyn.pvPowerTimeConstantS = 0.050;
dyn.pvEmergencyCurtailmentTimeConstantS = 0.030;
dyn.secondaryDispatchTimeConstantS = 0.60;
dyn.voltageTimeConstantS = 0.050;
dyn.activeDeficitVoltageGainPu = 0.040;
dyn.dieselGovernorTimeConstantS = 0.20;
dyn.dieselTripTimeConstantS = 0.020;
dyn.gridStiffTimeConstantS = 0.020;
dyn.gridConnectedBessTransitionTimeS = 0.40;
dyn.gridPhaseLockTimeConstantS = 0.050;

limits.bessDischargeKW = bessDischargeLimitKW;
limits.bessChargeKW = bessChargeLimitKW;
limits.inverterKVA = sizing.inverterRatingKilowatts; % unity-pf kW rating used as kVA for this equivalent model

sync.frequencyCorrectionHzPerDeg = 0.004;
sync.maxFrequencyCorrectionHz = 0.050;
sync.maxPhaseErrorDeg = 0.50;
sync.maxFrequencyErrorHz = 0.030;
sync.maxVoltageErrorPu = 0.020;
sync.holdTimeS = 0.10;

% ---------------------------------------------------------------------
% Real operating hours from the optimizer output loaded above.
% Hour 1 = 01-Jan-2025 00:00 local study time.
baseTime = datetime(P.site.calendarYear,1,1,0,0,0);

% S1: high-PV point where the grid is still importing after BESS reaches 0.5C.
% This makes the loss of grid power visible while keeping strong PV penetration.
i1 = 7092; % 23-Oct-2025 11:00
s1 = baseScenario(1,'S1_grid_loss_islanding',6.0,dyn,limits,sync);
s1.operatingPoint = opPoint(i1,critical,noncritical,pvAvailable,baseTime);
s1.operatingPoint.pvInitialKW = s1.operatingPoint.pvAvailableKW;
s1.operatingPoint.bessInitialKW = bessDischargeLimitKW;
s1.operatingPoint.dieselInitialKW = 0;
s1.operatingPoint.gridInitialKW = s1.operatingPoint.totalLoadKW ...
    - s1.operatingPoint.pvInitialKW - s1.operatingPoint.bessInitialKW;
s1.events.gridLossTimeS = 2.0;
s1.events.loadShedTimeS = 2.10; % 100 ms after grid loss
s1.initial = makeInitial(s1,P,dyn,limits,true);
s1.gridConnectedBessTargetKW = s1.operatingPoint.bessInitialKW;
s1.titleLines = { ...
    'Scenario 1 - Grid loss -> islanding', ...
    'Before: Grid + PV + BESS ON, Diesel OFF | After: PV + BESS (GFM) ON, Grid + Diesel OFF; non-critical load shed'};

% S2: +20% critical-load step; BESS can still cover the new deficit.
i2 = 1400; % 28-Feb-2025 07:00
s2 = baseScenario(2,'S2_load_step_20pct',6.0,dyn,limits,sync);
s2.operatingPoint = opPoint(i2,critical,noncritical,pvAvailable,baseTime);
s2.operatingPoint.noncriticalLoadKW = 0;
s2.operatingPoint.totalLoadKW = s2.operatingPoint.criticalLoadKW;
s2.operatingPoint.pvInitialKW = s2.operatingPoint.pvAvailableKW;
s2.operatingPoint.bessInitialKW = s2.operatingPoint.criticalLoadKW - s2.operatingPoint.pvInitialKW;
s2.operatingPoint.dieselInitialKW = 0;
s2.operatingPoint.gridInitialKW = 0;
s2.events.loadStepTimeS = 2.0;
s2.events.loadStepFraction = 0.20;
s2.initial = makeInitial(s2,P,dyn,limits,false);
s2.gridConnectedBessTargetKW = 0;
s2.titleLines = { ...
    'Scenario 2 - +20% critical-load step', ...
    'Islanded | ON: PV + BESS (GFM) | OFF: Grid + Diesel | Non-critical load OFF'};

% S3A: automatically choose an islanded operating hour where the BESS is
% charging before the event and a 50% PV loss creates the largest deficit
% that the current BESS power limit can still cover. This keeps the scenario
% valid automatically when the optimized PV/BESS sizing changes.
i3a = selectPvDropOperatingHour(critical,pvAvailable,bessDischargeLimitKW,0.50);
s3a = baseScenario(31,'S3A_PV_drop_50pct',10.0,dyn,limits,sync);
s3a.operatingPoint = opPoint(i3a,critical,noncritical,pvAvailable,baseTime);
s3a.operatingPoint.noncriticalLoadKW = 0;
s3a.operatingPoint.totalLoadKW = s3a.operatingPoint.criticalLoadKW;
s3a.operatingPoint.pvInitialKW = s3a.operatingPoint.pvAvailableKW;
% Dispatch logic: excess PV charges BESS before the drop.
s3a.operatingPoint.bessInitialKW = max(-bessChargeLimitKW, ...
    s3a.operatingPoint.criticalLoadKW - s3a.operatingPoint.pvInitialKW);
s3a.operatingPoint.dieselInitialKW = 0;
s3a.operatingPoint.gridInitialKW = 0;
s3a.events.pvDropTimeS = 2.0;
s3a.events.pvDropFraction = 0.50;
s3a.initial = makeInitial(s3a,P,dyn,limits,false);
s3a.gridConnectedBessTargetKW = 0;
s3a.titleLines = { ...
    'Scenario 3A - 50% PV availability drop', ...
    'Islanded | ON: PV + BESS (GFM) | OFF: Grid + Diesel | BESS swings from charging to discharging'};

% S3B: PV + BESS cannot serve the peak critical load, so diesel is already on.
% Then the diesel breaker trips. This is intentionally the insufficient-capacity case.
i3b = 17; % 01-Jan-2025 16:00
s3b = baseScenario(32,'S3B_diesel_trip',4.0,dyn,limits,sync);
s3b.operatingPoint = opPoint(i3b,critical,noncritical,pvAvailable,baseTime);
s3b.operatingPoint.noncriticalLoadKW = 0;
s3b.operatingPoint.totalLoadKW = s3b.operatingPoint.criticalLoadKW;
s3b.operatingPoint.pvInitialKW = s3b.operatingPoint.pvAvailableKW;
s3b.operatingPoint.bessInitialKW = bessDischargeLimitKW;
s3b.operatingPoint.dieselInitialKW = s3b.operatingPoint.criticalLoadKW ...
    - s3b.operatingPoint.pvInitialKW - s3b.operatingPoint.bessInitialKW;
s3b.operatingPoint.gridInitialKW = 0;
s3b.events.dieselTripTimeS = 2.0;
s3b.initial = makeInitial(s3b,P,dyn,limits,false);
s3b.gridConnectedBessTargetKW = 0;
s3b.titleLines = { ...
    'Scenario 3B - Diesel trip while diesel is required', ...
    'Before: PV + BESS (GFM) + Diesel ON, Grid OFF | After: PV + BESS ON, Grid + Diesel OFF -> sustained power deficit'};

% S4: islanded PV+BESS operation, grid returns but PCC remains open until synced.
i4 = 34; % 02-Jan-2025 09:00
s4 = baseScenario(4,'S4_grid_restoration_resynchronization',8.0,dyn,limits,sync);
s4.operatingPoint = opPoint(i4,critical,noncritical,pvAvailable,baseTime);
s4.operatingPoint.noncriticalLoadKW = 0;
s4.operatingPoint.totalLoadKW = s4.operatingPoint.criticalLoadKW;
s4.operatingPoint.pvInitialKW = s4.operatingPoint.pvAvailableKW;
s4.operatingPoint.bessInitialKW = s4.operatingPoint.criticalLoadKW - s4.operatingPoint.pvInitialKW;
s4.operatingPoint.dieselInitialKW = 0;
s4.operatingPoint.gridInitialKW = 0;
s4.events.gridReturnTimeS = 2.0;
s4.initial = makeInitial(s4,P,dyn,limits,false);
s4.initial.phaseErrorDeg = 15.0; % explicit synchronization stress assumption
s4.gridConnectedBessTargetKW = 0;
s4.titleLines = { ...
    'Scenario 4 - Grid restoration and resynchronization', ...
    'Before: PV + BESS (GFM) ON, Grid breaker OPEN, Diesel OFF | After sync: Grid + PV ON, BESS grid-connected, Diesel OFF'};

scenarios = [s1 s2 s3a s3b s4];

printScenarioSummary(scenarios,bessDischargeLimitKW);

% ---------------------------------------------------------------------
% Build and simulate.
mdl = 'microgrid_vf_model';
modelPath = fullfile(scriptDir,[mdl '.slx']);
if ~isfile(modelPath)
    build_microgrid_vf_model();
end
load_system(modelPath);

outDir = fullfile(scriptDir,'vf_results');
if ~isfolder(outDir)
    mkdir(outDir);
end

results = struct([]);
for k = 1:numel(scenarios)
    SC = scenarios(k); %#ok<NASGU>
    assignin('base','SC',SC);
    fprintf('\nRunning %s ...\n',SC.name);

    simOut = sim(mdl, ...
        'StopTime',num2str(SC.stopTimeS,'%.6g'), ...
        'ReturnWorkspaceOutputs','on');

    ts = simOut.get('microgridY');
    t = ts.Time;
    Y = squeeze(ts.Data);
    if size(Y,1) ~= numel(t)
        Y = Y.';
    end

    T = array2table([t Y], 'VariableNames', { ...
        'Time_s','Frequency_Hz','Voltage_LL_RMS_V','Grid_kW','PV_kW', ...
        'BESS_kW','Diesel_kW','CriticalLoad_kW','NoncriticalLoad_kW', ...
        'TotalLoad_kW','TotalGeneration_kW','PhaseError_deg','PCC_Closed', ...
        'PV_Available_kW','BESS_GFM_Active','Diesel_Active','Noncritical_Connected'});

    csvPath = fullfile(outDir,[SC.name '.csv']);
    writetable(T,csvPath);

    fig = plotScenario(T,SC);
    pngPath = fullfile(outDir,[SC.name '.png']);
    exportgraphics(fig,pngPath,'Resolution',300);
    savefig(fig,fullfile(outDir,[SC.name '.fig']));

    results(k).scenario = SC; %#ok<AGROW>
    results(k).table = T; %#ok<AGROW>
    results(k).png = pngPath; %#ok<AGROW>

    fprintf('  saved: %s\n',pngPath);
end

save(fullfile(outDir,'microgrid_vf_all_results.mat'),'results','scenarios','-v7.3');
close_system(mdl,0);

fprintf('\nDone. Results folder:\n  %s\n',outDir);
fprintf('\nImportant: this is a reduced-order V/f model. Use a detailed Simscape/EMT network for fault current and CCT.\n');
end

% =====================================================================

function idx = selectPvDropOperatingHour(critical,pvAvailable,bessLimitKW,dropFraction)
% Select the most demanding recoverable PV-drop case for the CURRENT sizing.
% Before the event PV must exceed critical load so the BESS is charging.
% After the PV drop, the resulting deficit must be positive but no larger
% than the BESS discharge-power limit.
postDropPv = pvAvailable .* (1.0 - dropFraction);
postDropDeficit = critical - postDropPv;

candidateMask = (pvAvailable > critical) & ...
                (postDropDeficit > 0) & ...
                (postDropDeficit <= bessLimitKW + 1e-9);

candidates = find(candidateMask);
if isempty(candidates)
    error(['No operating hour satisfies the Scenario 3A requirements for the current sizing. ' ...
           'Reduce the PV-drop fraction or revise the scenario selection logic.']);
end

% Pick the candidate closest to the BESS limit: strongest disturbance that
% should still recover without diesel support.
[~,localIndex] = max(postDropDeficit(candidates));
idx = candidates(localIndex);
end

function S = baseScenario(id,name,stopTimeS,dyn,limits,sync)
S.id = id;
S.name = name;
S.stopTimeS = stopTimeS;
S.dyn = dyn;
S.limits = limits;
S.sync = sync;
S.events = struct();
S.operatingPoint = struct();
S.initial = struct();
S.gridConnectedBessTargetKW = 0;
S.titleLines = {'',''};
end

function O = opPoint(idx,critical,noncritical,pvAvailable,baseTime)
O.hourIndex = idx;
O.timestamp = baseTime + hours(idx-1);
O.criticalLoadKW = critical(idx);
O.noncriticalLoadKW = noncritical(idx);
O.totalLoadKW = critical(idx) + noncritical(idx);
O.pvAvailableKW = pvAvailable(idx);
O.pvInitialKW = pvAvailable(idx);
O.bessInitialKW = 0;
O.dieselInitialKW = 0;
O.gridInitialKW = 0;
end

function I = makeInitial(S,P,dyn,limits,isGridConnected)
I.fHz = dyn.nominalFrequencyHz;
I.vPu = 1.0;
I.pBessKW = S.operatingPoint.bessInitialKW;
I.pPvKW = S.operatingPoint.pvInitialKW;
I.pDieselKW = S.operatingPoint.dieselInitialKW;
I.phaseErrorDeg = 0.0;
I.pccClosed = isGridConnected;

if isGridConnected
    I.qBessKvar = 0.0;
else
    qLoad = S.operatingPoint.totalLoadKW * tan(acos(dyn.loadPowerFactor));
    if S.operatingPoint.totalLoadKW > 0
        qDiesel = qLoad * max(S.operatingPoint.dieselInitialKW,0) ...
            / S.operatingPoint.totalLoadKW;
    else
        qDiesel = 0;
    end
    qCap = sqrt(max(limits.inverterKVA^2 - I.pBessKW^2,0));
    I.qBessKvar = min(max(qLoad-qDiesel,-qCap),qCap);
end

% Keep the project's initial SOC available for documentation. The short
% transient simulations do not materially change energy content.
I.socFraction = P.battery.stateOfChargeInitialFraction;
end

function printScenarioSummary(S,bessLimit)
fprintf('Selected real operating points and events:\n');
for k = 1:numel(S)
    O = S(k).operatingPoint;
    fprintf('\n%s\n',S(k).name);
    fprintf('  Hour: %s (index %d)\n',char(O.timestamp),O.hourIndex);
    fprintf('  Critical %.1f kW | Non-critical %.1f kW | PV available %.1f kW\n', ...
        O.criticalLoadKW,O.noncriticalLoadKW,O.pvAvailableKW);
    fprintf('  Initial: Grid %.1f | PV %.1f | BESS %.1f | Diesel %.1f kW\n', ...
        O.gridInitialKW,O.pvInitialKW,O.bessInitialKW,O.dieselInitialKW);
end
fprintf('\nBESS +/- power limit used = %.1f kW. Positive BESS power = discharge; negative = charge.\n',bessLimit);
end

function fig = plotScenario(T,SC)
fig = figure('Color','w','Name',SC.name,'Position',[80 80 1200 820]);

if SC.id == 1 || SC.id == 32 || SC.id == 4
    tl = tiledlayout(4,1,'TileSpacing','compact','Padding','compact');
else
    tl = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
end

% Frequency
ax1 = nexttile(tl);
plot(T.Time_s,T.Frequency_Hz,'LineWidth',1.5);
hold on; yline(SC.dyn.nominalFrequencyHz,'--','50 Hz');
addEventLines(ax1,SC);
ylabel('Frequency (Hz)'); grid on;
title('Bus frequency');

% Voltage
ax2 = nexttile(tl);
plot(T.Time_s,T.Voltage_LL_RMS_V,'LineWidth',1.5);
hold on; yline(SC.dyn.busVoltageLLRmsV,'--','400 V');
addEventLines(ax2,SC);
ylabel('V_{LL,RMS} (V)'); grid on;
title('Equivalent bus voltage');

% Source powers + total load
ax3 = nexttile(tl);
plot(T.Time_s,T.Grid_kW,'LineWidth',1.25); hold on;
plot(T.Time_s,T.PV_kW,'LineWidth',1.25);
plot(T.Time_s,T.BESS_kW,'LineWidth',1.25);
plot(T.Time_s,T.Diesel_kW,'LineWidth',1.25);
plot(T.Time_s,T.TotalLoad_kW,'k--','LineWidth',1.35);
addEventLines(ax3,SC);
ylabel('Active power (kW)'); grid on;
legend('Grid (+import)','PV','BESS (+discharge)','Diesel','Load','Location','best');
title('Source active powers and load');

if SC.id == 1
    ax4 = nexttile(tl);
    plot(T.Time_s,T.CriticalLoad_kW,'LineWidth',1.4); hold on;
    plot(T.Time_s,T.NoncriticalLoad_kW,'LineWidth',1.4);
    plot(T.Time_s,T.TotalLoad_kW,'k--','LineWidth',1.3);
    addEventLines(ax4,SC);
    ylabel('Load (kW)'); xlabel('Time (s)'); grid on;
    legend('Critical','Non-critical','Total','Location','best');
    title('Load shedding: non-critical load disconnects 100 ms after grid loss');

elseif SC.id == 32
    ax4 = nexttile(tl);
    plot(T.Time_s,T.TotalGeneration_kW,'LineWidth',1.5); hold on;
    plot(T.Time_s,T.TotalLoad_kW,'k--','LineWidth',1.5);
    addEventLines(ax4,SC);
    ylabel('Power (kW)'); xlabel('Time (s)'); grid on;
    legend('Total available generation','Critical load','Location','best');
    title('Why frequency does not recover: generation remains below load');

elseif SC.id == 4
    ax4 = nexttile(tl);
    yyaxis left
    plot(T.Time_s,T.PhaseError_deg,'LineWidth',1.5);
    ylabel('Phase error (deg)');
    yyaxis right
    stairs(T.Time_s,T.PCC_Closed,'LineWidth',1.2);
    ylabel('PCC closed'); ylim([-0.05 1.05]);
    xlabel('Time (s)'); grid on;
    title('Synchronization and PCC closure');
    idx = find(diff(T.PCC_Closed) > 0.5,1,'first');
    if ~isempty(idx)
        xline(T.Time_s(idx+1),'--',sprintf('PCC closes %.3f s',T.Time_s(idx+1)), ...
            'LabelVerticalAlignment','middle');
    end
else
    xlabel(ax3,'Time (s)');
end

sgtitle(SC.titleLines,'FontWeight','bold','FontSize',13);
end

function addEventLines(ax,SC)
hold(ax,'on');
switch SC.id
    case 1
        xline(ax,SC.events.gridLossTimeS,':','Grid opens');
        xline(ax,SC.events.loadShedTimeS,':','Non-critical shed');
    case 2
        xline(ax,SC.events.loadStepTimeS,':','+20% load');
    case 31
        xline(ax,SC.events.pvDropTimeS,':','PV -50%');
    case 32
        xline(ax,SC.events.dieselTripTimeS,':','Diesel trips');
    case 4
        xline(ax,SC.events.gridReturnTimeS,':','Grid returns; PCC open');
end
end
