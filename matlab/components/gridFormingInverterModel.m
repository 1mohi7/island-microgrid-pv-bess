function inverter = gridFormingInverterModel(ratingKilowatts, generatorRatingKilowatts, P)
%GRIDFORMINGINVERTERMODEL  Islanding capability of the grid-forming interface.
%
%   inverter = gridFormingInverterModel(ratingKilowatts, generatorRatingKilowatts, P)
%
%   THE ISLANDING CONSTRAINT AS ORIGINALLY SPECIFIED DOES NOT BIND HERE, and it
%   is worth being explicit about why rather than leaving a reviewer to find it.
%   The brief justified making the inverter an independent decision variable on
%   the grounds that "in islanded mode it must carry the entire served load".
%   But the served load while islanded is CRITICAL load only, which peaks at
%   259 kW on this feeder. The inverter is in practice sized by grid-connected
%   battery throughput, with the critical peak as a hard LOWER bound. The search
%   range is therefore 259-1000 kW, not 0-1500 kW, and the justification in the
%   write-up must be restated to match.
%
%   Because the generator is grid-forming capable, the island's serving capacity
%   is inverter rating PLUS generator rating. If the generator were only
%   grid-following, the inverter alone would set the ceiling.

inverter.ratingKilowatts        = ratingKilowatts;
inverter.conversionEfficiency   = P.inverter.conversionEfficiencyFraction;
inverter.serviceLifeYears       = P.inverter.serviceLifeYears;

if P.generator.isGridFormingCapable
    inverter.islandServingCapacityKilowatts = ratingKilowatts + generatorRatingKilowatts;
else
    inverter.islandServingCapacityKilowatts = ratingKilowatts;
end

inverter.canHoldIsland = @(servedLoadKilowatts) ...
    servedLoadKilowatts <= inverter.islandServingCapacityKilowatts + 1e-9;

end
