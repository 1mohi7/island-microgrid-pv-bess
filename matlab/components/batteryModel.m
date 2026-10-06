function battery = batteryModel(energyCapacityKilowattHours, inverterRatingKilowatts, P)
%BATTERYMODEL  Battery limits and lifetime. State recursion lives in dispatch.
%
%   battery = batteryModel(energyCapacityKilowattHours, inverterRatingKilowatts, P)
%
%   Returns a struct of derived limits plus function handles for the energy
%   accounting. Keeping the physics here and the state machine in
%   dispatchSimulator lets each be checked separately.
%
%   THREE DISTINCT THRESHOLDS, never collapsed into one:
%     stateOfChargeMinimumFraction      hard physical/warranty floor, never
%                                       violated in any mode
%     stateOfChargeIslandFloorFraction  floor while islanded; below this the
%                                       unit cannot reliably hold the
%                                       voltage/frequency reference
%     reserveStateOfCharge(t)           grid-connected dispatch floor; the
%                                       POLICY variable that separates the
%                                       outage-blind and outage-aware designs
%                                       (see reservePolicy.m)
%
%   Efficiency convention: the caller works in DELIVERED (terminal) kilowatt
%   hours throughout and never has to remember which side of the converter it
%   is on. Discharge efficiency is applied on the way out, charge efficiency on
%   the way in.

battery.energyCapacityKilowattHours = energyCapacityKilowattHours;

% Battery power is limited by the tighter of C-rate and the grid-forming
% inverter through which it flows.
battery.maximumChargePowerKilowatts = min( ...
    energyCapacityKilowattHours * P.battery.maximumChargeRatePerHour, ...
    inverterRatingKilowatts);
battery.maximumDischargePowerKilowatts = min( ...
    energyCapacityKilowattHours * P.battery.maximumDischargeRatePerHour, ...
    inverterRatingKilowatts);

battery.usableEnergyKilowattHours = energyCapacityKilowattHours * ...
    (P.battery.stateOfChargeMaximumFraction - P.battery.stateOfChargeMinimumFraction);

battery.chargeEfficiency    = P.battery.oneWayChargeEfficiencyFraction;
battery.dischargeEfficiency = P.battery.oneWayDischargeEfficiencyFraction;

% --------------------------------------------------------------- handles
battery.availableDischargeEnergy = @(stateOfCharge, floorFraction) ...
    max(stateOfCharge - floorFraction, 0) * energyCapacityKilowattHours * ...
    battery.dischargeEfficiency;

battery.acceptableChargeEnergy = @(stateOfCharge) ...
    max(P.battery.stateOfChargeMaximumFraction - stateOfCharge, 0) * ...
    energyCapacityKilowattHours / battery.chargeEfficiency;

end

% =====================================================================
function years = batteryLifeYears(energyCapacityKilowattHours, ...
                                  annualDischargeKilowattHours, P) %#ok<DEFNU>
%BATTERYLIFEYEARS  Whichever binds first: throughput cycle life, or calendar life.
%
%   Degradation is counted by THROUGHPUT against rated cycle life, as specified.
%   No electrochemical model; at annual resolution it would add nothing.
%
%   Exposed for reference; economicsModel.m carries its own copy so that it can
%   be called without constructing a battery struct.

if energyCapacityKilowattHours <= 0 || annualDischargeKilowattHours <= 0
    years = P.battery.calendarLifeYears;
    return;
end
cyclesPerYear = annualDischargeKilowattHours / energyCapacityKilowattHours;
throughputLifeYears = P.battery.ratedCycleLifeAtEightyPercentDepth / cyclesPerYear;
years = min(throughputLifeYears, P.battery.calendarLifeYears);
end
