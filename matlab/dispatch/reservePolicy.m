function policy = reservePolicy(policyName, statistics, inputs, P, lookaheadHours)
%RESERVEPOLICY  Build a reserve state-of-charge policy object.
%
%   policy = reservePolicy(policyName, statistics, inputs, P, lookaheadHours)
%
%   policyName is one of:
%
%     'blind'         reserve = stateOfChargeMinimumFraction, every hour. The
%                     battery arbitrages freely against the tariff and is
%                     routinely near-empty by early evening, which is exactly
%                     when the shedding roster lands. Used by the OUTAGE-BLIND
%                     design, and by the cross-evaluation cells.
%
%     'aware'         reserve(t) = expected critical energy at risk over the
%                     next lookahead window, converted to a state-of-charge
%                     fraction and clipped. Computed from the FITTED OUTAGE
%                     STATISTICS conditioned on month and hour of day. NEVER
%                     from the realised trace. Used by the OUTAGE-AWARE design.
%
%     'forewarned'    reserve(t) driven by the ACTUAL announced outages in the
%                     trace - shedding and maintenance only, NEVER faults. This
%                     is the value-of-forewarning variant and it is the ONLY
%                     policy permitted to read a trace. A controller holding a
%                     published shedding roster knows those hours; it does not
%                     know when a fault will strike.
%
%   THIS FILE EXISTS SO THAT THE BLIND AND AWARE DESIGNS DIFFER BY ONE ARGUMENT
%   AT THE CALL SITE. If they ever differ by more than that, the experiment has
%   stopped isolating the policy and the comparison is worthless. The reserve
%   profile is precomputed before the dispatch loop runs, which also keeps the
%   inner loop free of branching on policy type.
%
%   Usage:
%       policy  = reservePolicy('aware', statistics, inputs, P, 6);
%       reserve = policy.buildProfile(batteryEnergyKilowattHours, causeCodes);
%
%   causeCodes is ignored by 'blind' and 'aware' and is required by
%   'forewarned'. Passing it unconditionally keeps every call site identical.

if nargin < 5 || isempty(lookaheadHours); lookaheadHours = 6; end

policy.name           = policyName;
policy.lookaheadHours = lookaheadHours;

stateOfChargeMinimum = P.battery.stateOfChargeMinimumFraction;
stateOfChargeMaximum = P.battery.stateOfChargeMaximumFraction;
hoursPerYear         = P.site.hoursPerYear;

% AUDIT FIX (item 3): during an outage the battery can only discharge down to
% the ISLAND floor (15%), not the warranty minimum (10%), and E_risk is energy
% at the LOAD, so the stored energy needed is E_risk / dischargeEfficiency.
% reserve = islandFloor + E_risk / (E_batt * etaDischarge)
stateOfChargeIslandFloor = P.battery.stateOfChargeIslandFloorFraction;
dischargeEfficiency      = P.battery.oneWayDischargeEfficiencyFraction;

switch lower(policyName)

    case 'blind'
        policy.readsTrace = false;
        policy.buildProfile = @(batteryEnergy, causeCodes) ...
            repmat(stateOfChargeMinimum, hoursPerYear, 1);

    case 'aware'
        % Expected foreseeable outage hours ahead, weighted by the critical load
        % expected to be PRESENT during those hours. The critical load is
        % averaged over the SAME forward window rather than taken at the current
        % hour, because the energy at risk is what the island will have to carry
        % during the outage, not what it is carrying now.
        expectedOutageHours = expectedForeseeableOutageHours(statistics, lookaheadHours, P);

        criticalLoad = inputs.criticalLoadKilowatts;
        padded = [criticalLoad; criticalLoad(1:lookaheadHours)];
        cumulative = [0; cumsum(padded)];
        forwardMeanCriticalLoad = (cumulative(lookaheadHours+1 : lookaheadHours+hoursPerYear) ...
                                 - cumulative(1:hoursPerYear)) / lookaheadHours;

        expectedEnergyAtRisk = expectedOutageHours .* forwardMeanCriticalLoad;
        policy.expectedEnergyAtRiskKilowattHours = expectedEnergyAtRisk;
        policy.readsTrace = false;

        policy.buildProfile = @(batteryEnergy, causeCodes) ...
            clipReserve(batteryEnergy, expectedEnergyAtRisk, ...
                        stateOfChargeMinimum, stateOfChargeMaximum, hoursPerYear, ...
                        stateOfChargeIslandFloor, dischargeEfficiency);

    case 'forewarned'
        policy.readsTrace = true;
        criticalLoad = inputs.criticalLoadKilowatts;
        foreseeableCauses = P.cause.foreseeable;

        policy.buildProfile = @(batteryEnergy, causeCodes) ...
            forewarnedReserve(batteryEnergy, causeCodes, criticalLoad, ...
                              foreseeableCauses, lookaheadHours, ...
                              stateOfChargeMinimum, stateOfChargeMaximum, hoursPerYear, ...
                              stateOfChargeIslandFloor, dischargeEfficiency);

    otherwise
        error('reservePolicy:unknown', ...
            'Unknown policy "%s". Use blind, aware or forewarned.', policyName);
end

end

% =====================================================================
function reserve = clipReserve(batteryEnergy, expectedEnergyAtRisk, ...
                               minimumFraction, maximumFraction, hoursPerYear, ...
                               islandFloorFraction, dischargeEfficiency)
if batteryEnergy <= 0
    reserve = repmat(minimumFraction, hoursPerYear, 1);
    return;
end
reserve = islandFloorFraction + ...
          expectedEnergyAtRisk / (batteryEnergy * dischargeEfficiency);
reserve = min(max(reserve, minimumFraction), maximumFraction);
end

% =====================================================================
function reserve = forewarnedReserve(batteryEnergy, causeCodes, criticalLoad, ...
                                     foreseeableCauses, lookaheadHours, ...
                                     minimumFraction, maximumFraction, hoursPerYear, ...
                                     islandFloorFraction, dischargeEfficiency)
if batteryEnergy <= 0
    reserve = repmat(minimumFraction, hoursPerYear, 1);
    return;
end
announced = double(ismember(causeCodes, foreseeableCauses));
energyAtRisk = announced .* criticalLoad;

padded = [energyAtRisk; energyAtRisk(1:lookaheadHours)];
cumulative = [0; cumsum(padded)];
forwardEnergy = cumulative(lookaheadHours+1 : lookaheadHours+hoursPerYear) - ...
                cumulative(1:hoursPerYear);

reserve = islandFloorFraction + ...
          forwardEnergy / (batteryEnergy * dischargeEfficiency);
reserve = min(max(reserve, minimumFraction), maximumFraction);
end
