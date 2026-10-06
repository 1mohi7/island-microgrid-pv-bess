function generator = dieselGeneratorModel(ratingKilowatts, P)
%DIESELGENERATORMODEL  Fuel curve, minimum loading, fuel-limited dispatch.
%
%   generator = dieselGeneratorModel(ratingKilowatts, P)
%
%   Linear fuel curve:
%       litresPerHour = intercept * ratingKilowatts + slope * outputKilowatts
%   The intercept is a RUNNING cost, not a standing one: zero fuel is burned
%   when the unit is off.
%
%   Minimum loading is 30% of rating and is never violated. Below it, wet
%   stacking is a real failure mode, and allowing the model to sit at 5% loading
%   would flatter the diesel option.
%
%   GRID-FORMING NOTE. The generator is reference-capable (Stage 1 decision,
%   option (a), which reflects real installations). While islanded it therefore
%   ADDS to what the island can carry rather than sitting behind the inverter,
%   and it assumes the voltage/frequency reference if the battery reaches its
%   island floor.

generator.ratingKilowatts = ratingKilowatts;
generator.minimumStableOutputKilowatts = ratingKilowatts * ...
    P.generator.minimumLoadingFractionOfRating;
generator.isGridFormingCapable = P.generator.isGridFormingCapable;

generator.fuelConsumptionLitresPerHour = @(outputKilowatts) ...
    fuelCurve(outputKilowatts, ratingKilowatts, P);

generator.specificFuelConsumptionLitresPerKilowattHour = @(outputKilowatts) ...
    fuelCurve(outputKilowatts, ratingKilowatts, P) ./ max(outputKilowatts, eps);

generator.carbonDioxideKilograms = @(fuelLitres) ...
    fuelLitres * P.generator.carbonDioxideEmissionFactorKgPerLitre;

end

% =====================================================================
function litresPerHour = fuelCurve(outputKilowatts, ratingKilowatts, P)
if outputKilowatts <= 0 || ratingKilowatts <= 0
    litresPerHour = 0;
    return;
end
litresPerHour = P.generator.fuelCurveInterceptLitresPerHourPerRatedKilowatt * ratingKilowatts ...
              + P.generator.fuelCurveSlopeLitresPerKilowattHour * outputKilowatts;
end

% =====================================================================
function ratingKilowatts = snapToCatalogue(continuousRating, P) %#ok<DEFNU>
%SNAPTOCATALOGUE  Nearest catalogue rating.
%
%   Applied inside FITNESS EVALUATION ONLY. The wolf's stored position stays
%   continuous so that the search landscape is not turned into a staircase.
%   Standard and defensible; documented in Methods.
%
%   Exposed here for reference; fitnessEvaluate.m carries the operative copy.

catalogue = P.generator.availableRatingsKilowatts;
[~, index] = min(abs(catalogue - continuousRating));
ratingKilowatts = catalogue(index);
end
