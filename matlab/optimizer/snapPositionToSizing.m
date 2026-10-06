function sizing = snapPositionToSizing(position, P)
%SNAPPOSITIONTOSIZING  Continuous wolf position -> buildable sizing.
%
%   Snapping happens HERE and only here. The wolf's STORED position is never
%   modified, so the search landscape stays continuous.
%
%   Continuous variables are QUANTISED to the cache grid so that the key and the
%   system are in one-to-one correspondence. See the note in fitnessEvaluator.m
%   for why that matters. The generator snaps to the discrete catalogue.
%
%   Quantising to 1 kW also makes every returned sizing buildable in whole
%   kilowatts, which is no loss at all.

rounding = P.optimisation.cacheRoundingKilowatts;

sizing.photovoltaicCapacityKilowatts = quantise(position(1), ...
    P.optimisation.photovoltaicCapacityBoundsKilowatts, rounding);

sizing.batteryEnergyCapacityKilowattHours = quantise(position(2), ...
    P.optimisation.batteryEnergyCapacityBoundsKilowattHours, rounding);

continuousGenerator = min(max(position(3), ...
    P.optimisation.generatorRatingBoundsKilowatts(1)), ...
    P.optimisation.generatorRatingBoundsKilowatts(2));
catalogue = P.generator.availableRatingsKilowatts;
[~, index] = min(abs(catalogue - continuousGenerator));
sizing.generatorRatingKilowatts = catalogue(index);

sizing.inverterRatingKilowatts = quantise(position(4), ...
    P.optimisation.inverterRatingBoundsKilowatts, rounding);

% AUDIT FIX (item 4): the 259 kW floor is for a grid-forming BESS inverter.
% With no battery there is nothing for it to convert, so it is not bought.
if sizing.batteryEnergyCapacityKilowattHours <= 0
    sizing.inverterRatingKilowatts = 0;
end

end

function value = quantise(raw, limits, rounding)
value = min(max(raw, limits(1)), limits(2));
value = round(value / rounding) * rounding;
end
