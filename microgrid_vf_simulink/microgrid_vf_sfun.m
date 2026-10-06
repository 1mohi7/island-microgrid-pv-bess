function microgrid_vf_sfun(block)
%MICROGRID_VF_SFUN Low-fidelity average-value microgrid V/f dynamics.
%
% This Level-2 MATLAB S-function is intentionally a reduced-order model for
% presentation-scale voltage/frequency transients and source power sharing.
% It is NOT an EMT/switching model and must not be used for fault current or
% critical-clearing-time studies.
%
% The active scenario is supplied in base-workspace struct SC by
% run_microgrid_vf_scenarios.m.

setup(block);
end

function setup(block)
block.NumDialogPrms  = 0;
block.NumInputPorts  = 0;
block.NumOutputPorts = 1;

block.SetPreCompPortInfoToDefaults;
block.OutputPort(1).Dimensions = 16;
block.OutputPort(1).DatatypeID = 0;      % double
block.OutputPort(1).Complexity = 'Real';

block.SampleTimes = [1e-3 0];
block.SimStateCompliance = 'DefaultSimState';

block.RegBlockMethod('PostPropagationSetup', @doPostPropSetup);
block.RegBlockMethod('InitializeConditions', @initializeConditions);
block.RegBlockMethod('Outputs', @outputs);
block.RegBlockMethod('Update', @update);
end

function doPostPropSetup(block)
% Discrete states
names = {'fHz','vPu','pBessKW','pPvKW','pDieselKW', ...
         'pBessRefKW','qBessKvar','thetaErrRad','syncHoldS','pccClosed'};
block.NumDworks = numel(names);
for k = 1:numel(names)
    block.Dwork(k).Name            = names{k};
    block.Dwork(k).Dimensions      = 1;
    block.Dwork(k).DatatypeID      = 0;
    block.Dwork(k).Complexity      = 'Real';
    block.Dwork(k).UsedAsDiscState = true;
end
end

function initializeConditions(block)
SC = evalin('base','SC');
block.Dwork(1).Data  = SC.initial.fHz;
block.Dwork(2).Data  = SC.initial.vPu;
block.Dwork(3).Data  = SC.initial.pBessKW;
block.Dwork(4).Data  = SC.initial.pPvKW;
block.Dwork(5).Data  = SC.initial.pDieselKW;
block.Dwork(6).Data  = SC.initial.pBessKW;
block.Dwork(7).Data  = SC.initial.qBessKvar;
block.Dwork(8).Data  = deg2rad(SC.initial.phaseErrorDeg);
block.Dwork(9).Data  = 0.0;
block.Dwork(10).Data = double(SC.initial.pccClosed);
end

function outputs(block)
SC = evalin('base','SC');
t  = block.CurrentTime;

fHz       = block.Dwork(1).Data;
vPu       = block.Dwork(2).Data;
pBessKW   = block.Dwork(3).Data;
pPvKW     = block.Dwork(4).Data;
pDieselKW = block.Dwork(5).Data;
thetaRad  = block.Dwork(8).Data;
pccMemory = block.Dwork(10).Data > 0.5;

S = scenarioState(SC,t,fHz,vPu,thetaRad,pccMemory);

if S.gridClosed
    pGridKW = S.pLoadKW - pPvKW - pBessKW - pDieselKW;
else
    pGridKW = 0.0;
end

pGenerationKW = pGridKW + pPvKW + pBessKW + pDieselKW;
phaseErrorDeg = rad2deg(wrapPiLocal(thetaRad));

% Output vector mapping:
%  1 f_Hz
%  2 V_LL_RMS_V
%  3 P_grid_kW (positive import, negative export)
%  4 P_PV_kW
%  5 P_BESS_kW (positive discharge, negative charge)
%  6 P_diesel_kW
%  7 P_critical_kW
%  8 P_noncritical_kW
%  9 P_load_total_kW
% 10 P_generation_total_kW
% 11 phase_error_deg
% 12 PCC_closed (1/0)
% 13 PV_available_kW
% 14 BESS_GFM_active (1/0)
% 15 diesel_active (1/0)
% 16 noncritical_connected (1/0)
block.OutputPort(1).Data = [ ...
    fHz; ...
    vPu * SC.dyn.busVoltageLLRmsV; ...
    pGridKW; ...
    pPvKW; ...
    pBessKW; ...
    pDieselKW; ...
    S.pCriticalKW; ...
    S.pNoncriticalKW; ...
    S.pLoadKW; ...
    pGenerationKW; ...
    phaseErrorDeg; ...
    double(S.gridClosed); ...
    S.pvAvailableKW; ...
    double(~S.gridClosed); ...
    double(pDieselKW > 1.0); ...
    double(S.pNoncriticalKW > 0.0)];
end

function update(block)
SC = evalin('base','SC');
t  = block.CurrentTime;
dt = SC.dyn.sampleTimeS;

fHz       = block.Dwork(1).Data;
vPu       = block.Dwork(2).Data;
pBessKW   = block.Dwork(3).Data;
pPvKW     = block.Dwork(4).Data;
pDieselKW = block.Dwork(5).Data;
pBessRef  = block.Dwork(6).Data;
qBessKvar = block.Dwork(7).Data;
thetaRad  = block.Dwork(8).Data;
syncHoldS = block.Dwork(9).Data;
pccMemory = block.Dwork(10).Data > 0.5;

S = scenarioState(SC,t,fHz,vPu,thetaRad,pccMemory);

% ---------------------------------------------------------------------
% PV active-power response. Scenario 1 uses a faster emergency curtailment
% response after non-critical load shedding.
if SC.id == 1 && t >= SC.events.loadShedTimeS
    tauPv = SC.dyn.pvEmergencyCurtailmentTimeConstantS;
else
    tauPv = SC.dyn.pvPowerTimeConstantS;
end
pPvNext = pPvKW + dt * (S.pvTargetKW - pPvKW) / tauPv;

% Diesel. A breaker trip is intentionally much faster than governor motion.
if SC.id == 32 && t >= SC.events.dieselTripTimeS
    tauDiesel = SC.dyn.dieselTripTimeConstantS;
else
    tauDiesel = SC.dyn.dieselGovernorTimeConstantS;
end
pDieselNext = pDieselKW + dt * (S.dieselTargetKW - pDieselKW) / tauDiesel;

if S.gridClosed
    % Grid-connected mode: utility is the stiff V/f reference.
    if SC.id == 1
        pBessRefTarget = SC.initial.pBessKW;   % retain pre-outage dispatch
    else
        pBessRefTarget = SC.gridConnectedBessTargetKW;
    end
    pBessRefNext = pBessRef + dt * (pBessRefTarget - pBessRef) ...
        / SC.dyn.gridConnectedBessTransitionTimeS;
    pBessCommand = clampLocal(pBessRef, -SC.limits.bessChargeKW, ...
        SC.limits.bessDischargeKW);
    pBessNext = pBessKW + dt * (pBessCommand - pBessKW) ...
        / SC.dyn.bessPowerTimeConstantS;

    fNext = fHz + dt * (SC.dyn.nominalFrequencyHz - fHz) ...
        / SC.dyn.gridStiffTimeConstantS;
    vNext = vPu + dt * (1.0 - vPu) / SC.dyn.gridStiffTimeConstantS;
    qBessNext = qBessKvar + dt * (0.0 - qBessKvar) ...
        / SC.dyn.bessReactiveTimeConstantS;

    if SC.id == 4
        % Once synchronized and connected, grid locks the phase difference.
        thetaNext = thetaRad + dt * (-thetaRad / SC.dyn.gridPhaseLockTimeConstantS);
    else
        thetaNext = thetaRad;
    end

else
    % -----------------------------------------------------------------
    % Islanded mode. BESS is the grid-forming source.
    pBessRefTarget = clampLocal(S.pLoadKW - pPvKW - pDieselKW, ...
        -SC.limits.bessChargeKW, SC.limits.bessDischargeKW);
    pBessRefNext = pBessRef + dt * (pBessRefTarget - pBessRef) ...
        / SC.dyn.secondaryDispatchTimeConstantS;

    pBessCommand = pBessRef + SC.dyn.bessPfDroopGainKWperHz ...
        * (S.frequencyReferenceHz - fHz);
    pBessCommand = clampLocal(pBessCommand, -SC.limits.bessChargeKW, ...
        SC.limits.bessDischargeKW);
    pBessNext = pBessKW + dt * (pBessCommand - pBessKW) ...
        / SC.dyn.bessPowerTimeConstantS;

    pMismatchKW = pPvKW + pDieselKW + pBessKW - S.pLoadKW;
    fDot = (SC.dyn.nominalFrequencyHz / (2*SC.dyn.effectiveInertiaConstantS)) ...
        * (pMismatchKW / SC.dyn.powerBaseKW) ...
        - (SC.dyn.nominalFrequencyHz / (2*SC.dyn.effectiveInertiaConstantS)) ...
        * (SC.dyn.frequencyDampingKWperHz / SC.dyn.powerBaseKW) ...
        * (fHz - S.frequencyReferenceHz);
    fNext = fHz + dt * fDot;

    % Reactive-power/voltage response. Load Q follows the 0.95-pf project
    % assumption. The BESS supplies the island Q requirement with Q-V droop.
    qLoadKvar = S.pLoadKW * tan(acos(SC.dyn.loadPowerFactor));
    if S.pLoadKW > 1e-9
        qDieselKvar = qLoadKvar * max(pDieselKW,0) / S.pLoadKW;
    else
        qDieselKvar = 0.0;
    end
    qCapacityKvar = sqrt(max(SC.limits.inverterKVA^2 - pBessKW^2,0));
    qCommandKvar = (qLoadKvar - qDieselKvar) ...
        + SC.dyn.bessQvDroopGainKvarPerPu * (1.0 - vPu);
    qCommandKvar = clampLocal(qCommandKvar,-qCapacityKvar,qCapacityKvar);
    qBessNext = qBessKvar + dt * (qCommandKvar - qBessKvar) ...
        / SC.dyn.bessReactiveTimeConstantS;

    qMismatchKvar = qLoadKvar - qDieselKvar - qBessKvar;
    pDeficitKW = max(S.pLoadKW - (pPvKW + pDieselKW + pBessKW),0);
    vTargetPu = 1.0 ...
        - SC.dyn.qvDroopFraction * (qMismatchKvar / SC.dyn.powerBaseKW) ...
        - SC.dyn.activeDeficitVoltageGainPu * (pDeficitKW / SC.dyn.powerBaseKW);
    vNext = vPu + dt * (vTargetPu - vPu) / SC.dyn.voltageTimeConstantS;

    thetaNext = thetaRad + dt * 2*pi*(fHz - SC.dyn.nominalFrequencyHz);
end

% ---------------------------------------------------------------------
% Scenario 4 synchronizer: grid can be present while PCC remains open.
% Close only after phase, frequency, and voltage mismatch remain inside the
% specified window for the required hold time.
pccNext = double(pccMemory);
if SC.id == 4 && ~pccMemory && t >= SC.events.gridReturnTimeS
    thetaDeg = rad2deg(wrapPiLocal(thetaRad));
    syncOk = abs(thetaDeg) <= SC.sync.maxPhaseErrorDeg ...
        && abs(fHz-SC.dyn.nominalFrequencyHz) <= SC.sync.maxFrequencyErrorHz ...
        && abs(vPu-1.0) <= SC.sync.maxVoltageErrorPu;
    if syncOk
        syncHoldNext = syncHoldS + dt;
    else
        syncHoldNext = 0.0;
    end
    if syncHoldNext >= SC.sync.holdTimeS
        pccNext = 1.0;
    end
else
    syncHoldNext = syncHoldS;
end

block.Dwork(1).Data  = fNext;
block.Dwork(2).Data  = vNext;
block.Dwork(3).Data  = pBessNext;
block.Dwork(4).Data  = pPvNext;
block.Dwork(5).Data  = pDieselNext;
block.Dwork(6).Data  = pBessRefNext;
block.Dwork(7).Data  = qBessNext;
block.Dwork(8).Data  = thetaNext;
block.Dwork(9).Data  = syncHoldNext;
block.Dwork(10).Data = pccNext;
end

function S = scenarioState(SC,t,fHz,vPu,thetaRad,pccMemory)
f0 = SC.dyn.nominalFrequencyHz;
S.frequencyReferenceHz = f0;
S.pCriticalKW    = SC.operatingPoint.criticalLoadKW;
S.pNoncriticalKW = 0.0;
S.pLoadKW        = S.pCriticalKW;
S.pvAvailableKW  = SC.operatingPoint.pvAvailableKW;
S.pvTargetKW     = SC.operatingPoint.pvInitialKW;
S.dieselTargetKW = SC.operatingPoint.dieselInitialKW;
S.gridClosed     = false;

switch SC.id
    case 1  % grid loss -> islanding
        S.gridClosed = t < SC.events.gridLossTimeS;
        if t < SC.events.loadShedTimeS
            S.pNoncriticalKW = SC.operatingPoint.noncriticalLoadKW;
        end
        S.pLoadKW = S.pCriticalKW + S.pNoncriticalKW;
        if t < SC.events.loadShedTimeS
            S.pvTargetKW = SC.operatingPoint.pvAvailableKW;
        else
            % Emergency island PV curtailment to the surviving critical load.
            S.pvTargetKW = min(SC.operatingPoint.pvAvailableKW,S.pCriticalKW);
        end
        S.dieselTargetKW = 0.0;

    case 2  % +20% critical load step
        if t >= SC.events.loadStepTimeS
            S.pCriticalKW = SC.operatingPoint.criticalLoadKW ...
                * (1.0 + SC.events.loadStepFraction);
        end
        S.pLoadKW = S.pCriticalKW;
        S.pvTargetKW = SC.operatingPoint.pvInitialKW;
        S.dieselTargetKW = 0.0;

    case 31 % 50% PV availability drop
        if t >= SC.events.pvDropTimeS
            S.pvAvailableKW = SC.operatingPoint.pvAvailableKW ...
                * (1.0 - SC.events.pvDropFraction);
        end
        S.pvTargetKW = S.pvAvailableKW;
        S.pLoadKW = S.pCriticalKW;
        S.dieselTargetKW = 0.0;

    case 32 % diesel trip
        S.pLoadKW = S.pCriticalKW;
        S.pvTargetKW = SC.operatingPoint.pvInitialKW;
        if t >= SC.events.dieselTripTimeS
            S.dieselTargetKW = 0.0;
        else
            S.dieselTargetKW = SC.operatingPoint.dieselInitialKW;
        end

    case 4  % grid restoration and resynchronization
        S.pLoadKW = S.pCriticalKW;
        S.pvTargetKW = SC.operatingPoint.pvInitialKW;
        S.dieselTargetKW = 0.0;
        S.gridClosed = pccMemory;
        if ~S.gridClosed && t >= SC.events.gridReturnTimeS
            thetaDeg = rad2deg(wrapPiLocal(thetaRad));
            deltaF = clampLocal(-SC.sync.frequencyCorrectionHzPerDeg*thetaDeg, ...
                -SC.sync.maxFrequencyCorrectionHz,SC.sync.maxFrequencyCorrectionHz);
            S.frequencyReferenceHz = f0 + deltaF;
        end

    otherwise
        error('Unknown scenario ID: %g',SC.id);
end

% Keep numerical references finite even if a caller modifies the scenario.
if ~isfinite(fHz) || ~isfinite(vPu)
    error('Non-finite state encountered in microgrid V/f model.');
end
end

function y = clampLocal(x,lo,hi)
y = min(max(x,lo),hi);
end

function y = wrapPiLocal(x)
y = atan2(sin(x),cos(x));
end
