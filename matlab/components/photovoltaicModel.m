function pv = photovoltaicModel(inputs, P)
%PHOTOVOLTAICMODEL  Irradiance -> plane of array -> cell temperature -> AC power.
%
%   pv = photovoltaicModel(inputs, P)
%
%   Returns a normalised 8760-hour series in kilowatts per kilowatt-peak
%   installed, computed ONCE at start-up. Photovoltaic power for any candidate
%   sizing is then a single scalar multiplication inside the optimizer, which is
%   what keeps the inner loop cheap.
%
%   DOUBLE-COUNTING GUARD. Four multiplicative factors, each applied EXACTLY
%   once:
%       irradiance ratio  x  derate (no temperature, no inverter)
%                         x  temperature correction
%                         x  inverter efficiency
%   The 0.84 derate is explicitly scoped to exclude temperature and inverter
%   efficiency. Halving the derate must halve the annual output exactly; if it
%   does not, something has crept into it.

geometry = solarGeometry(inputs.timestamps, P);

% ------------------------------------------------- plane of array (Perez 1990)
pv.planeOfArrayIrradianceWattsPerSquareMetre = perezTransposition( ...
    inputs.globalHorizontalIrradianceWattsPerSquareMetre, ...
    inputs.directNormalIrradianceWattsPerSquareMetre, ...
    inputs.diffuseHorizontalIrradianceWattsPerSquareMetre, ...
    geometry, P.site.arrayTiltDegrees, P.site.arrayAzimuthDegrees);

% ------------------------------------------------- cell temperature (NOCT)
pv.cellTemperatureCelsius = inputs.ambientTemperatureCelsius + ...
    ((P.photovoltaic.nominalOperatingCellTemperatureCelsius - 20.0) / 800.0) .* ...
    pv.planeOfArrayIrradianceWattsPerSquareMetre;

% ------------------------------------------------- power per installed kW
irradianceRatio = pv.planeOfArrayIrradianceWattsPerSquareMetre / ...
                  P.photovoltaic.referenceIrradianceWattsPerSquareMetre;
temperatureCorrection = 1.0 + P.photovoltaic.temperatureCoefficientOfPowerPerCelsius .* ...
    (pv.cellTemperatureCelsius - P.photovoltaic.referenceCellTemperatureCelsius);

generation = irradianceRatio ...
           * P.photovoltaic.directCurrentSystemDerateFraction ...
          .* temperatureCorrection ...
           * P.photovoltaic.inverterEfficiencyFraction;
pv.generationPerInstalledKilowatt = max(generation, 0);

% ------------------------------------------------- diagnostics
pv.annualYieldKilowattHoursPerInstalledKilowatt = sum(pv.generationPerInstalledKilowatt);
pv.capacityFactor = pv.annualYieldKilowattHoursPerInstalledKilowatt / P.site.hoursPerYear;
pv.annualGlobalHorizontalKilowattHoursPerSquareMetre = ...
    sum(inputs.globalHorizontalIrradianceWattsPerSquareMetre) / 1000;
pv.annualPlaneOfArrayKilowattHoursPerSquareMetre = ...
    sum(pv.planeOfArrayIrradianceWattsPerSquareMetre) / 1000;
pv.transpositionGainFraction = pv.annualPlaneOfArrayKilowattHoursPerSquareMetre / ...
    pv.annualGlobalHorizontalKilowattHoursPerSquareMetre - 1;

daylight = pv.planeOfArrayIrradianceWattsPerSquareMetre > 50;
pv.meanDaytimeCellTemperatureCelsius = mean(pv.cellTemperatureCelsius(daylight));
weights = pv.generationPerInstalledKilowatt / sum(pv.generationPerInstalledKilowatt);
pv.outputWeightedCellTemperatureCelsius = sum(pv.cellTemperatureCelsius .* weights);

% Sanity gate. 0.151 expected at 3% soiling and a 0.84 derate.
band = P.photovoltaic.expectedCapacityFactorRange;
if pv.capacityFactor < band(1) || pv.capacityFactor > band(2)
    warning('photovoltaicModel:capacityFactor', ...
        ['Capacity factor %.4f falls outside the expected band [%.2f %.2f]. ' ...
         'Recheck derate, tilt, or data alignment before trusting any result.'], ...
        pv.capacityFactor, band(1), band(2));
end

end

% =====================================================================
function planeOfArray = perezTransposition(globalHorizontal, directNormal, ...
                                           diffuseHorizontal, geometry, ...
                                           tiltDegrees, azimuthDegrees)
%PEREZTRANSPOSITION  Perez et al. (1990) anisotropic sky diffuse model.

zenith  = geometry.solarZenithDegrees;
azimuth = geometry.solarAzimuthDegrees;
airMass = geometry.relativeAirMass;
airMass(isnan(airMass)) = 40;                 % night: any large value, gated below
extraterrestrial = geometry.extraterrestrialDirectNormalWattsPerSquareMetre;

% Angle of incidence on the tilted plane.
cosIncidence = cosd(zenith) * cosd(tiltDegrees) + ...
               sind(zenith) * sind(tiltDegrees) .* cosd(azimuth - azimuthDegrees);
cosIncidence = max(cosIncidence, 0);

% --------------------------------------------------------------- beam
beamOnPlane = directNormal .* cosIncidence;

% --------------------------------------------------------------- ground reflected
groundAlbedo = 0.2;
groundReflected = globalHorizontal * groundAlbedo * (1 - cosd(tiltDegrees)) / 2;

% --------------------------------------------------------------- sky diffuse
zenithRadians = deg2rad(min(zenith, 90));
kappa = 1.041;

% Sky clearness epsilon
epsilon = ((diffuseHorizontal + directNormal) ./ max(diffuseHorizontal, 1e-9) + ...
           kappa * zenithRadians.^3) ./ (1 + kappa * zenithRadians.^3);
epsilon(diffuseHorizontal <= 0) = 1;

% Sky brightness delta
delta = diffuseHorizontal .* airMass ./ extraterrestrial;

% Perez coefficient bins (Perez 1990, Table 6, all-sites composite)
epsilonBinEdges = [1.000 1.065 1.230 1.500 1.950 2.800 4.500 6.200 Inf];
F11 = [-0.0083  0.1299  0.3297  0.5682  0.8730  1.1326  1.0602  0.6777];
F12 = [ 0.5877  0.6826  0.4869  0.1875 -0.3920 -1.2367 -1.5999 -0.3273];
F13 = [-0.0621 -0.1514 -0.2211 -0.2951 -0.3616 -0.4118 -0.3589 -0.2504];
F21 = [-0.0596 -0.0189  0.0554  0.1090  0.2256  0.2878  0.2642  0.1561];
F22 = [ 0.0721  0.0660 -0.0640 -0.1519 -0.4620 -0.8230 -1.1272 -1.3765];
F23 = [-0.0220 -0.0288 -0.026  -0.0139  0.0012  0.0559  0.1311  0.2506];

binIndex = discretize(epsilon, epsilonBinEdges);
binIndex(isnan(binIndex)) = 1;

circumsolarBrightening = max(0, F11(binIndex)' + F12(binIndex)' .* delta + ...
                                F13(binIndex)' .* zenithRadians);
horizonBrightening     =        F21(binIndex)' + F22(binIndex)' .* delta + ...
                                F23(binIndex)' .* zenithRadians;

% Circumsolar geometric factors a and b
aFactor = max(0, cosIncidence);
bFactor = max(cosd(85), cosd(zenith));

skyDiffuse = diffuseHorizontal .* ( ...
      (1 - circumsolarBrightening) * (1 + cosd(tiltDegrees)) / 2 ...
    + circumsolarBrightening .* aFactor ./ bFactor ...
    + horizonBrightening * sind(tiltDegrees));
skyDiffuse = max(skyDiffuse, 0);

planeOfArray = beamOnPlane + skyDiffuse + groundReflected;
planeOfArray(zenith >= 90) = diffuseHorizontal(zenith >= 90) * ...
                             (1 + cosd(tiltDegrees)) / 2;   % night / below horizon
planeOfArray = max(planeOfArray, 0);
planeOfArray(~isfinite(planeOfArray)) = 0;

end
