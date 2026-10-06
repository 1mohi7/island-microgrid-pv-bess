function economics = economicsModel(sizing, dispatchResult, P)
%ECONOMICSMODEL  25-year net present cost, replacement, salvage, levelised cost.
%
%   economics = economicsModel(sizing, dispatchResult, P)
%
%       netPresentCost = capital + replacement + operationAndMaintenance
%                      + fuel + gridImport + landLease
%                      - exportRevenue - salvage - landSalvage
%
% ---------------------------------------------------------------------
% DISCOUNTING IS REAL, NOT NOMINAL. The 9% discount rate is a REAL rate, so the
% fuel and tariff escalation rates applied here are also REAL: 2.5%/yr and
% 3.0%/yr, meaning diesel and electricity rise that much FASTER than general
% inflation. Diesel ends at 1.85x its starting real price over 25 years, which
% is aggressive and is one of the sweep parameters for exactly that reason.
% Mixing a real discount rate with nominal escalation, or the reverse, is the
% classic way to get a net present cost wrong by tens of percent.
%
% ---------------------------------------------------------------------
% PHOTOVOLTAIC DEGRADATION is handled without re-simulating dispatch for each of
% the 25 years. Dispatch runs once on a representative year; in later years the
% lost photovoltaic energy is bought from the grid at that year's escalated
% tariff. This assumes the marginal displaced source is the grid rather than the
% battery or generator, which is a good approximation here because the feeder
% imports in almost every hour. DECLARED IN LIMITATIONS, not hidden.
%
% ---------------------------------------------------------------------
% LAND. Priced on the ARRAY FOOTPRINT only; battery, generator and switchgear
% sit inside the same fenced parcel and add no separate acreage at this scale.
% EXCLUDED from the civil/engineering percentage, because that fraction is a
% soft cost on EQUIPMENT and applying it to land would inflate the figure for no
% physical reason.
%   - Acquisition is charged at the PREMIUM multiple of market price (stamp
%     duty, registration, aggregation premium, facilitation payments).
%   - Salvage is realised at MARKET value grown at the real appreciation rate,
%     NOT at the acquisition-inflated price: the premium buys permission and
%     assembly, and cannot be resold.
%   - Note that what drives the result is the GAP between the appreciation rate
%     and the discount rate. If they were equal, land would be free in net
%     present cost terms except for the premium.

horizon      = P.costs.projectHorizonYears;
discountRate = P.costs.realDiscountRateFraction;
takaPerDollar = P.costs.bangladeshiTakaPerUnitedStatesDollar;

photovoltaicCapacity = sizing.photovoltaicCapacityKilowatts;
batteryEnergy        = sizing.batteryEnergyCapacityKilowattHours;
generatorRating      = sizing.generatorRatingKilowatts;
inverterRating       = sizing.inverterRatingKilowatts;

% =====================================================================
% CAPITAL
% =====================================================================
c.photovoltaicCapitalUsd = photovoltaicCapacity * ...
    P.costs.photovoltaicCapitalCostUsdPerKilowattPeak;

c.batteryEnergyCapitalUsd = batteryEnergy * ...
    P.costs.batteryEnergyCapitalCostUsdPerKilowattHour;

% ONE cost path for the grid-forming interface. The premium applies to the
% POWER line only. An earlier structure carried both a "grid-forming premium"
% and a separate "grid-forming inverter all-in $/kW", which were two ways of
% computing the same number and risked being summed.
c.powerConversionCapitalUsd = inverterRating * ...
    P.costs.batteryPowerConversionCapitalCostUsdPerKilowatt * ...
    (1 + P.costs.gridFormingPremiumFractionOnPowerConversion);

c.generatorCapitalUsd = generatorRating * ...
    P.costs.dieselGeneratorCapitalCostUsdPerKilowatt;

if generatorRating > 0
    c.fuelTankCapitalUsd = P.costs.fuelTankCapitalCostUsd;
else
    c.fuelTankCapitalUsd = 0;
end

% AUDIT FIX (item 8): only charged when a microgrid is actually built.
hasMicrogridAssets = (photovoltaicCapacity + batteryEnergy + generatorRating + inverterRating) > 0;
c.controllerAndInterconnectionCapitalUsd = hasMicrogridAssets * ...
    P.costs.microgridControllerAndInterconnectionCapitalCostUsd;

% AUDIT FIX (item 7): transformer cost scales with rating (0 $/kVA by default).
transformerCostPerKva = 0;
if isfield(P.costs, 'interconnectionTransformerCostUsdPerKilovoltAmpere')
    transformerCostPerKva = P.costs.interconnectionTransformerCostUsdPerKilovoltAmpere;
end
c.interconnectionTransformerCapitalUsd = hasMicrogridAssets * transformerCostPerKva * ...
    P.tariff.interconnectionTransformerRatingKilovoltAmperes;

landAcres = photovoltaicCapacity / 1000 * P.costs.landAreaAcresPerMegawattPeak;
if strcmpi(P.costs.landTenure, 'purchase')
    c.landCapitalUsd = landAcres * P.costs.landPurchaseCostUsdPerAcre * ...
                       P.costs.landAcquisitionPremiumMultiplier;
else
    c.landCapitalUsd = 0;
end

equipmentSubtotal = c.photovoltaicCapitalUsd + c.batteryEnergyCapitalUsd + ...
                    c.powerConversionCapitalUsd + c.generatorCapitalUsd + ...
                    c.fuelTankCapitalUsd;
c.civilAndEngineeringCapitalUsd = equipmentSubtotal * ...
    P.costs.civilAndEngineeringProcurementConstructionFraction;

totalCapital = c.photovoltaicCapitalUsd + c.batteryEnergyCapitalUsd + ...
               c.powerConversionCapitalUsd + c.generatorCapitalUsd + ...
               c.fuelTankCapitalUsd + c.controllerAndInterconnectionCapitalUsd + ...
               c.interconnectionTransformerCapitalUsd + ...
               c.civilAndEngineeringCapitalUsd + c.landCapitalUsd;

% =====================================================================
% REPLACEMENT
% =====================================================================
c.batteryReplacementPresentValueUsd  = 0;
c.inverterReplacementPresentValueUsd = 0;
c.generatorOverhaulPresentValueUsd   = 0;

batteryLife = batteryLifeYearsLocal(batteryEnergy, ...
    dispatchResult.batteryDischargeKilowattHours, P);

if batteryEnergy > 0
    replacementCost = c.batteryEnergyCapitalUsd * ...
                      P.costs.batteryReplacementCostFractionOfOriginal;
    year = batteryLife;
    while year < horizon
        c.batteryReplacementPresentValueUsd = c.batteryReplacementPresentValueUsd + ...
            replacementCost * presentValueFactor(year, discountRate);
        year = year + batteryLife;
    end
end

if inverterRating > 0
    year = P.inverter.serviceLifeYears;
    while year < horizon
        c.inverterReplacementPresentValueUsd = c.inverterReplacementPresentValueUsd + ...
            c.powerConversionCapitalUsd * presentValueFactor(year, discountRate);
        year = year + P.inverter.serviceLifeYears;
    end
end

% Generator overhauls are driven by cumulative RUNNING HOURS, not calendar years.
if generatorRating > 0 && dispatchResult.generatorRunningHours > 0
    yearsBetweenOverhauls = P.generator.overhaulIntervalRunningHours / ...
                            dispatchResult.generatorRunningHours;
    overhaulCost = c.generatorCapitalUsd * ...
                   P.costs.dieselGeneratorOverhaulCostFractionOfCapital;
    year = yearsBetweenOverhauls;
    while year < horizon
        c.generatorOverhaulPresentValueUsd = c.generatorOverhaulPresentValueUsd + ...
            overhaulCost * presentValueFactor(year, discountRate);
        year = year + yearsBetweenOverhauls;
    end
end

totalReplacement = c.batteryReplacementPresentValueUsd + ...
                   c.inverterReplacementPresentValueUsd + ...
                   c.generatorOverhaulPresentValueUsd;

% =====================================================================
% ANNUAL RECURRING CASH FLOWS
% =====================================================================
annualOperationCost = photovoltaicCapacity * P.costs.photovoltaicOperationCostUsdPerKilowattYear ...
    + c.batteryEnergyCapitalUsd * P.costs.batteryOperationCostFractionOfCapitalPerYear ...
    + c.powerConversionCapitalUsd * P.costs.inverterOperationCostFractionOfCapitalPerYear ...
    + sum(dispatchResult.hourly.generatorOutput) * ...
      P.costs.dieselGeneratorOperationCostUsdPerKilowattHour;

annualFuelCostYearOne = dispatchResult.fuelConsumedLitres * ...
    P.costs.dieselFuelPriceBdtPerLitre / takaPerDollar;

% Quarterly net-metering settlement.
boundaries = P.tariff.quarterBoundaryHours;
quarterlyImport = zeros(4,1); quarterlyExport = zeros(4,1);
for quarter = 1:4
    window = (boundaries(quarter)+1) : boundaries(quarter+1);
    quarterlyImport(quarter) = sum(dispatchResult.hourly.gridImport(window));
    quarterlyExport(quarter) = sum(dispatchResult.hourly.gridExport(window));
end
grid = gridConnectionModel(P);
[energyCostYearOne, exportRevenueYearOne] = grid.settleNetMetering(quarterlyImport, quarterlyExport);

annualDemandChargeYearOne = sum(dispatchResult.monthlyPeakImportKilowatts) / ...
    P.tariff.assumedPowerFactor * ...
    P.tariff.demandChargeBdtPerKilovoltAmpereMonth / takaPerDollar;

energyCostYearOne         = energyCostYearOne * P.tariff.billingMultiplier;
annualDemandChargeYearOne = annualDemandChargeYearOne * P.tariff.billingMultiplier;

photovoltaicGenerationYearOne = dispatchResult.photovoltaicGenerationKilowattHours;

c.operationAndMaintenancePresentValueUsd = 0;
c.fuelPresentValueUsd            = 0;
c.gridEnergyPresentValueUsd      = 0;
c.gridDemandChargePresentValueUsd = 0;
c.exportRevenuePresentValueUsd   = 0;

for year = 1:horizon
    discountFactor   = presentValueFactor(year, discountRate);
    fuelEscalation   = (1 + P.costs.dieselFuelRealEscalationRatePerYear)^(year-1);
    tariffEscalation = (1 + P.costs.gridTariffRealEscalationRatePerYear)^(year-1);

    c.operationAndMaintenancePresentValueUsd = c.operationAndMaintenancePresentValueUsd + ...
        annualOperationCost * discountFactor;
    c.fuelPresentValueUsd = c.fuelPresentValueUsd + ...
        annualFuelCostYearOne * fuelEscalation * discountFactor;

    degradationLossFraction = P.photovoltaic.annualDegradationRateFractionPerYear * (year-1);
    degradationMakeupCost = photovoltaicGenerationYearOne * degradationLossFraction * ...
        P.tariff.importTariffBdtPerKilowattHour / takaPerDollar * P.tariff.billingMultiplier;

    c.gridEnergyPresentValueUsd = c.gridEnergyPresentValueUsd + ...
        (energyCostYearOne + degradationMakeupCost) * tariffEscalation * discountFactor;
    c.gridDemandChargePresentValueUsd = c.gridDemandChargePresentValueUsd + ...
        annualDemandChargeYearOne * tariffEscalation * discountFactor;
    c.exportRevenuePresentValueUsd = c.exportRevenuePresentValueUsd + ...
        exportRevenueYearOne * tariffEscalation * discountFactor;
end

% =====================================================================
% LAND LEASE / LAND SALVAGE
% =====================================================================
c.landLeasePresentValueUsd   = 0;
c.landSalvagePresentValueUsd = 0;

if strcmpi(P.costs.landTenure, 'lease')
    annualLease = landAcres * P.costs.landLeaseCostUsdPerAcreYear;
    for year = 1:horizon
        c.landLeasePresentValueUsd = c.landLeasePresentValueUsd + ...
            annualLease * presentValueFactor(year, discountRate);
    end
elseif P.costs.landRetainsFullValueAtHorizon
    marketValueToday = landAcres * P.costs.landPurchaseCostUsdPerAcre;
    c.landSalvagePresentValueUsd = marketValueToday * ...
        (1 + P.costs.landRealAppreciationRatePerYear)^horizon * ...
        presentValueFactor(horizon, discountRate);
end

% =====================================================================
% SALVAGE (equipment)
% =====================================================================
c.salvagePresentValueUsd = equipmentSalvage(sizing, c, batteryLife, ...
                                            dispatchResult, P) ;

% =====================================================================
% TOTAL
% =====================================================================
economics.breakdown       = c;
economics.totalCapitalUsd = totalCapital;
economics.totalReplacementUsd = totalReplacement;
economics.landAcres       = landAcres;

economics.netPresentCostUsd = totalCapital + totalReplacement ...
    + c.operationAndMaintenancePresentValueUsd ...
    + c.fuelPresentValueUsd ...
    + c.gridEnergyPresentValueUsd ...
    + c.gridDemandChargePresentValueUsd ...
    + c.landLeasePresentValueUsd ...
    - c.exportRevenuePresentValueUsd ...
    - c.salvagePresentValueUsd ...
    - c.landSalvagePresentValueUsd;

% ---------------------------------------------------------------------
% LEVELISED COST. The DENOMINATOR IS DISCOUNTED TOO. That is the standard
% convention and is what makes the result comparable to a published tariff.
% Undiscounted energy in the denominator would understate the levelised cost by
% roughly a factor of three at 9% over 25 years.
servedEnergyYearOne = dispatchResult.totalLoadKilowattHours - ...
    dispatchResult.unservedCriticalKilowattHours - ...
    dispatchResult.unservedNonCriticalKilowattHours;
discountedEnergy = 0;
for year = 1:horizon
    discountedEnergy = discountedEnergy + servedEnergyYearOne * ...
                       presentValueFactor(year, discountRate);
end
if discountedEnergy > 0
    economics.levelisedCostUsdPerKilowattHour = economics.netPresentCostUsd / discountedEnergy;
else
    economics.levelisedCostUsdPerKilowattHour = Inf;
end
economics.levelisedCostBdtPerKilowattHour = ...
    economics.levelisedCostUsdPerKilowattHour * takaPerDollar;

% ---------------------------------------------------------------------
% VALUE OF LOST LOAD. REPORTED SEPARATELY, never folded into the net present
% cost. The optimisation constrains loss-of-load probability, so pricing
% unserved energy in the objective as well would penalise the same failure twice
% and quietly change what is being optimised.
economics.unservedEnergyCostUsd = ...
    dispatchResult.unservedCriticalKilowattHours * ...
        P.costs.valueOfLostLoadCriticalUsdPerKilowattHour + ...
    dispatchResult.unservedNonCriticalKilowattHours * ...
        P.costs.valueOfLostLoadNonCriticalUsdPerKilowattHour;

economics.carbonDioxideTonnesPerYear = ...
    (dispatchResult.fuelConsumedLitres * P.generator.carbonDioxideEmissionFactorKgPerLitre + ...
     dispatchResult.gridImportKilowattHours * ...
     P.tariff.carbonDioxideEmissionFactorKgPerKilowattHour) / 1000;

end

% =====================================================================
function factor = presentValueFactor(yearIndex, realDiscountRate)
% Discount a cash flow occurring at the END of yearIndex (1-based).
factor = 1 / (1 + realDiscountRate)^yearIndex;
end

% =====================================================================
function years = batteryLifeYearsLocal(energyCapacity, annualDischarge, P)
% Whichever binds first: throughput-driven cycle life, or calendar life.
if energyCapacity <= 0 || annualDischarge <= 0
    years = P.battery.calendarLifeYears;
    return;
end
cyclesPerYear = annualDischarge / energyCapacity;
throughputLife = P.battery.ratedCycleLifeAtEightyPercentDepth / cyclesPerYear;
years = min(throughputLife, P.battery.calendarLifeYears);
end

% =====================================================================
function salvage = equipmentSalvage(sizing, c, batteryLife, dispatchResult, P)
% Straight-line remaining value of each asset at the end of the horizon.
horizon = P.costs.projectHorizonYears;
discountFactor = presentValueFactor(horizon, P.costs.realDiscountRateFraction);
salvage = 0;

% Photovoltaic lifetime equals the horizon, so nothing remains.
if P.photovoltaic.serviceLifeYears > horizon
    remaining = (P.photovoltaic.serviceLifeYears - horizon) / P.photovoltaic.serviceLifeYears;
    salvage = salvage + c.photovoltaicCapitalUsd * remaining;
end

if sizing.batteryEnergyCapacityKilowattHours > 0 && batteryLife > 0
    ageAtHorizon = ageAtHorizonLocal(horizon, batteryLife);
    remaining = (batteryLife - ageAtHorizon) / batteryLife;
    if horizon >= batteryLife
        unitCost = c.batteryEnergyCapitalUsd * P.costs.batteryReplacementCostFractionOfOriginal;
    else
        unitCost = c.batteryEnergyCapitalUsd;
    end
    salvage = salvage + unitCost * remaining;
end

if sizing.inverterRatingKilowatts > 0
    ageAtHorizon = ageAtHorizonLocal(horizon, P.inverter.serviceLifeYears);
    remaining = (P.inverter.serviceLifeYears - ageAtHorizon) / P.inverter.serviceLifeYears;
    salvage = salvage + c.powerConversionCapitalUsd * remaining;
end

if sizing.generatorRatingKilowatts > 0
    cumulativeHours = dispatchResult.generatorRunningHours * horizon;
    hoursSinceOverhaul = ageAtHorizonLocal(cumulativeHours, P.generator.overhaulIntervalRunningHours);
    remaining = 1 - hoursSinceOverhaul / P.generator.overhaulIntervalRunningHours;
    salvage = salvage + c.generatorCapitalUsd * remaining;
end

salvage = salvage * discountFactor;
end

% =====================================================================
function age = ageAtHorizonLocal(horizon, life)
% AUDIT FIX (item 10): replacements happen only while year < horizon, so a
% unit whose life divides the horizon exactly is AT end of life (age = life),
% not brand new (mod = 0). Tolerance guards against floating-point lives.
age = mod(horizon, life);
if horizon >= life && (age < 1e-9 || life - age < 1e-9)
    age = life;
end
end
