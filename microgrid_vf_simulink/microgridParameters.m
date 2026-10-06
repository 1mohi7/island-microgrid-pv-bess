function P = microgridParameters()
%MICROGRIDPARAMETERS  All parameters for the Feni feeder microgrid sizing study.
%
%   P = microgridParameters() returns a nested struct. Every value carries a
%   comment giving its source, and where it is uncertain, its sweep range.
%
%   Variables are spelled out in full. No single-letter symbols. Units are
%   carried in the name of every physical quantity.
%
%   See ASSUMPTIONS.txt for the full sourcing narrative.

% =====================================================================
% SITE
% =====================================================================
P.site.latitudeDegreesNorth              = 22.95;   % Feni district centroid
P.site.longitudeDegreesEast              = 91.40;
P.site.standardMeridianDegreesEast       = 90.00;   % Bangladesh Standard Time
P.site.elevationMetresAboveSeaLevel      = 8.0;
P.site.utcOffsetHours                    = 6;       % UTC+6, no daylight saving
P.site.arrayTiltDegrees                  = 23.0;    % approx. site latitude
P.site.arrayAzimuthDegrees               = 180.0;   % due south
P.site.calendarYear                      = 2025;    % non-leap, matches input files
P.site.hoursPerYear                      = 8760;

% =====================================================================
% PHOTOVOLTAIC ARRAY
% =====================================================================
% Direct-current derate, NREL PVWatts v5 loss taxonomy:
%   soiling 3 + shading 3 + mismatch 2 + wiring 2 + connections 0.5
%   + light-induced degradation 1.5 + nameplate 1 + availability 3 = 16%
% EXCLUDES temperature (separate cell-temperature model below) and inverter
% efficiency (separate factor below). Do NOT read 0.84 as an all-in derate.
P.photovoltaic.soilingLossFraction                     = 0.03;
P.photovoltaic.soilingLossSweep                        = [0.03 0.08];
P.photovoltaic.directCurrentSystemDerateFraction       = 0.84;
P.photovoltaic.directCurrentSystemDerateSweep          = [0.79 0.86];

P.photovoltaic.temperatureCoefficientOfPowerPerCelsius = -0.004;  % -0.4 %/degC
P.photovoltaic.nominalOperatingCellTemperatureCelsius  = 45.0;
P.photovoltaic.referenceCellTemperatureCelsius         = 25.0;
P.photovoltaic.referenceIrradianceWattsPerSquareMetre  = 1000.0;

P.photovoltaic.inverterEfficiencyFraction              = 0.97;
P.photovoltaic.inverterEfficiencySweep                 = [0.96 0.98];

P.photovoltaic.annualDegradationRateFractionPerYear    = 0.005;
P.photovoltaic.annualDegradationSweep                  = [0.003 0.007];
P.photovoltaic.serviceLifeYears                        = 25;

% Sanity gate. At 3% soiling and a 0.84 derate the modelled capacity factor is
% 0.151, inside the published Bangladesh band.
P.photovoltaic.expectedCapacityFactorRange             = [0.15 0.19];

% =====================================================================
% BATTERY ENERGY STORAGE SYSTEM
% =====================================================================
P.battery.roundTripEfficiencyFraction        = 0.90;
P.battery.roundTripEfficiencySweep           = [0.85 0.93];

% Three DISTINCT thresholds, deliberately kept separate.
P.battery.stateOfChargeMinimumFraction       = 0.10;  % hard warranty floor
P.battery.stateOfChargeMaximumFraction       = 0.95;
P.battery.stateOfChargeIslandFloorFraction   = 0.15;  % grid-forming reference hold
P.battery.stateOfChargeInitialFraction       = 0.50;

P.battery.maximumChargeRatePerHour           = 0.5;   % 0.5C
P.battery.maximumDischargeRatePerHour        = 0.5;
P.battery.chargeRateSweep                    = [0.25 1.0];

P.battery.ratedCycleLifeAtEightyPercentDepth = 5500;
P.battery.cycleLifeSweep                     = [4000 7000];
P.battery.calendarLifeYears                  = 12;
P.battery.calendarLifeSweep                  = [10 15];

% Derived one-way efficiencies: sqrt of round trip, each way.
P.battery.oneWayChargeEfficiencyFraction     = sqrt(P.battery.roundTripEfficiencyFraction);
P.battery.oneWayDischargeEfficiencyFraction  = sqrt(P.battery.roundTripEfficiencyFraction);

% =====================================================================
% DIESEL GENERATOR
% =====================================================================
% Linear fuel curve: litresPerHour = intercept*ratingKW + slope*outputKW
P.generator.fuelCurveInterceptLitresPerHourPerRatedKilowatt = 0.08;
P.generator.fuelCurveSlopeLitresPerKilowattHour             = 0.25;
P.generator.minimumLoadingFractionOfRating                  = 0.30;
P.generator.minimumLoadingSweep                             = [0.25 0.40];

P.generator.overhaulIntervalRunningHours                    = 15000;
P.generator.overhaulIntervalSweep                           = [12000 20000];

P.generator.fuelTankCapacityLitres                          = 5000.0;
P.generator.fuelTankCapacitySweepLitres                     = [2500 5000 10000];
P.generator.allowRefillDuringForcedOutage                   = false;
% Tank refills over 24 hours once supply is restored; no refill while islanded.
P.generator.fuelRefillRateLitresPerHour                     = 5000.0/24.0;

P.generator.carbonDioxideEmissionFactorKgPerLitre           = 2.68;

% Catalogue trimmed to ratings a 259 kW critical bus could plausibly use, plus a
% zero option so the optimizer can decline diesel entirely. The brief's 0-1500 kW
% range is absurd against a 259 kW island.
P.generator.availableRatingsKilowatts = [0 100 125 150 200 250 300 400 500];

% The generator is grid-forming capable and takes the voltage/frequency reference
% if the battery reaches its island floor. Stated in Methods.
P.generator.isGridFormingCapable = true;

% =====================================================================
% GRID-FORMING INVERTER
% =====================================================================
P.inverter.conversionEfficiencyFraction = 0.96;
P.inverter.serviceLifeYears             = 15;
P.inverter.serviceLifeSweep             = [12 20];

% =====================================================================
% GRID CONNECTION AND TARIFF
% =====================================================================
% ASSUMED point value. The feeder class-energy breakdown is still missing.
% 8.6 chosen for a residential-plus-irrigation-heavy mix; full 8-13 swept.
P.tariff.importTariffBdtPerKilowattHour   = 8.60;
P.tariff.importTariffSweepBdt             = [8.0 13.0];

% BERC June 2026 weighted-average bulk tariff, referenced by Net Metering
% Guidelines 2025 section 3.5(b) for customers at 33 kV and below.
P.tariff.exportCreditBdtPerKilowattHour   = 8.39;
P.tariff.exportCreditSweepBdt             = [6.5 9.5];

% Dedicated 2.0 MVA interconnection transformer. NMG 2025 section 3.3(c) caps
% medium-voltage export at 80% of transformer rating -> 1,600 kW at unity power
% factor.
P.tariff.interconnectionTransformerRatingKilovoltAmperes = 2000.0;
P.tariff.exportPowerCapFractionOfTransformer             = 0.80;
P.tariff.exportPowerCapKilowatts = P.tariff.interconnectionTransformerRatingKilovoltAmperes ...
                                 * P.tariff.exportPowerCapFractionOfTransformer;
P.tariff.interconnectionTransformerSweepKva = [2000 2500 3000];

P.tariff.settlementPeriodMonths            = 3;      % NMG 2025 section 3.5(f)
% Quarter boundaries as hour indices in a non-leap year (end of Mar/Jun/Sep/Dec).
P.tariff.quarterBoundaryHours              = [0 2160 4344 6552 8760];

P.tariff.demandChargeBdtPerKilovoltAmpereMonth = 42.0;   % ASSUMED
P.tariff.assumedPowerFactor                    = 0.95;

P.tariff.peakPeriodStartHour = 17;   % 17:00-23:00
P.tariff.peakPeriodEndHour   = 23;

P.tariff.carbonDioxideEmissionFactorKgPerKilowattHour = 0.67;

% Value added tax 5% on energy plus demand charge, on-time payment rebate 5%.
P.tariff.billingMultiplier = (1 + 0.05) * (1 - 0.05);

% =====================================================================
% COSTS AND FINANCE
% =====================================================================
P.costs.bangladeshiTakaPerUnitedStatesDollar = 122.0;
P.costs.exchangeRateSweep                    = [110 135];

P.costs.realDiscountRateFraction             = 0.09;  % stated REAL, not nominal
P.costs.discountRateSweep                    = [0.06 0.12];
P.costs.projectHorizonYears                  = 25;

P.costs.photovoltaicCapitalCostUsdPerKilowattPeak = 650.0;
P.costs.photovoltaicCapitalCostSweep              = [500 850];
P.costs.photovoltaicOperationCostUsdPerKilowattYear = 12.0;

% ------------------------------ LAND ---------------------------------
% Footprint 3 acres per megawatt-peak (The Business Standard, Apr 2025).
% Price ASSUMED, triangulated from ACWA Power's ~30%-of-project-cost statement
% for Rampal (back-solves to ~$93k/acre) and Feni-district transactions
% (~$41k-164k/acre). Wide sweep matters more than the base case.
P.costs.landAreaAcresPerMegawattPeak       = 3.0;
P.costs.landAreaSweepAcresPerMegawatt      = [3.0 4.0];
P.costs.landPurchaseCostUsdPerAcre         = 50000.0;   % MARKET price
P.costs.landPurchaseCostSweepUsdPerAcre    = [40000 160000];
% What is actually PAID is roughly double market: stamp duty, registration, the
% premium to aggregate many small holdings, and district-level facilitation
% payments. Applied to ACQUISITION only.
P.costs.landAcquisitionPremiumMultiplier   = 2.0;
P.costs.landAcquisitionPremiumSweep        = [1.5 2.5];
% Land outruns general inflation in Bangladesh. Salvage is MARKET value grown at
% this REAL rate and discounted at the real discount rate. NOTE: what drives the
% result is the GAP between this rate and the discount rate. At 9% they cancel
% and land is free in net present cost terms except for the premium.
P.costs.landRealAppreciationRatePerYear    = 0.06;
P.costs.landRealAppreciationSweep          = [0.03 0.09];
P.costs.landRetainsFullValueAtHorizon      = true;
P.costs.landLeaseCostUsdPerAcreYear        = 5400.0;    % ~6% of purchase price
P.costs.landTenure                         = 'purchase'; % 'purchase' or 'lease'

% ------------------------- BATTERY AND INVERTER ----------------------
% ONE cost path only. The grid-forming premium applies to the POWER line only.
%   C_battery = energy($/kWh x kWh) + power($/kW x kW) x (1 + premium)
% Balance-of-system/engineering is applied once at system level below, never
% again inside the power or premium figures.
P.costs.batteryEnergyCapitalCostUsdPerKilowattHour        = 280.0;
P.costs.batteryEnergyCapitalCostSweep                     = [200 400];
P.costs.batteryPowerConversionCapitalCostUsdPerKilowatt   = 120.0;
P.costs.gridFormingPremiumFractionOnPowerConversion       = 0.20;
P.costs.gridFormingPremiumSweep                           = [0.10 0.30];
P.costs.batteryOperationCostFractionOfCapitalPerYear      = 0.02;
P.costs.batteryReplacementCostFractionOfOriginal          = 0.70;

P.costs.dieselGeneratorCapitalCostUsdPerKilowatt          = 350.0;
P.costs.dieselGeneratorCapitalCostSweep                   = [300 500];
P.costs.dieselGeneratorOperationCostUsdPerKilowattHour    = 0.03;
P.costs.dieselGeneratorOverhaulCostFractionOfCapital      = 0.30;
P.costs.fuelTankCapitalCostUsd                            = 5000.0;

P.costs.inverterOperationCostFractionOfCapitalPerYear     = 0.01;

P.costs.microgridControllerAndInterconnectionCapitalCostUsd = 50000.0;
P.costs.civilAndEngineeringProcurementConstructionFraction  = 0.10;

P.costs.dieselFuelPriceBdtPerLitre        = 115.0;
P.costs.dieselFuelPriceSweepBdt           = [80 150];
% REAL escalation, paired with the REAL discount rate above. Diesel ends at
% 1.85x its starting real price over 25 years - aggressive, hence the sweep.
P.costs.dieselFuelRealEscalationRatePerYear = 0.025;
P.costs.gridTariffRealEscalationRatePerYear = 0.030;

% Value of lost load. REPORTED SEPARATELY, never folded into net present cost:
% the optimisation constrains loss-of-load probability, so pricing unserved
% energy in the objective as well would penalise the same failure twice.
P.costs.valueOfLostLoadCriticalUsdPerKilowattHour    = 10.0;
P.costs.valueOfLostLoadNonCriticalUsdPerKilowattHour = 1.0;

% =====================================================================
% OPTIMISATION
% =====================================================================
% Bounds revised after Stage 1. The grid-forming inverter no longer runs to
% 1500 kW: the islanded bus is critical load only, peaking at 259 kW, so the
% inverter is in practice sized by grid-connected battery throughput with the
% critical peak as a hard lower bound.
P.optimisation.photovoltaicCapacityBoundsKilowatts     = [0    3000];
P.optimisation.batteryEnergyCapacityBoundsKilowattHours = [0    6000];
P.optimisation.generatorRatingBoundsKilowatts          = [0     500];
P.optimisation.inverterRatingBoundsKilowatts           = [259  1000];

% SPEED-REDUCED for the land-cost sweep study (originals: 30 / 100 / 30).
% The sweep runs the optimizer 21 times per design, so the per-point budget
% has to be cut. Keep these low while sweeping; restore for a headline run.
P.optimisation.populationSize     = 20;   % was 30
P.optimisation.maximumIterations  = 75;   % was 100 (still past the ~iter-30 knee)
P.optimisation.independentRuns    = 5;    % was 30

P.optimisation.lossOfLoadProbabilityThresholds = [0.005 0.01 0.02 0.05 0.10];

% Penalty on the loss-of-load constraint:
%   penalty = linearWeight*violation + quadraticWeight*violation^2
% A PURE QUADRATIC (as the brief specified) is far too weak near the boundary:
% at 5e8 a violation of 0.001 costs $500 against an $8M objective and would sail
% through as the winner. The linear term makes that same violation cost $2M,
% exceeding the entire spread of net present cost across the feasible space.
P.optimisation.constraintPenaltyLinearWeightUsd    = 2.0e9;
P.optimisation.constraintPenaltyQuadraticWeightUsd = 5.0e10;

P.optimisation.numberOfInSampleTraces = 3;   % was 5 (reduced for sweep speed)
P.optimisation.numberOfHeldOutTraces  = 100;
P.optimisation.inSampleTraceSeed      = 20250101;
P.optimisation.heldOutTraceSeed       = 77777777;   % SEALED, never used in fitness

% Cache/quantisation grid. The evaluated sizing is quantised to the SAME grid as
% the cache key. Those two must go together: rounding only the key while leaving
% the sizing continuous makes 432.2 kW and 432.4 kW share a cache entry while
% being different systems, and one silently inherits the other's result.
P.optimisation.cacheRoundingKilowatts = 1.0;

% =====================================================================
% OUTAGE CAUSE CODES
% =====================================================================
P.cause.none        = 0;
P.cause.shedding    = 1;
P.cause.fault       = 2;
P.cause.maintenance = 3;
% Causes the operator knows about in advance. Shedding is rostered and
% published; maintenance is notified. Faults are not.
P.cause.foreseeable = [P.cause.shedding P.cause.maintenance];

end
