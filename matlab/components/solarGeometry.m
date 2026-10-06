function geometry = solarGeometry(timestamps, P)
%SOLARGEOMETRY  Sun position and extraterrestrial irradiance for each hour.
%
%   Solar position is evaluated at the MIDPOINT of each hour. NASA POWER hourly
%   values are hour-averaged and labelled by the hour they start, so evaluating
%   geometry at the label would bias the sun position half an hour early all
%   year and systematically distort the morning and evening shoulders.
%
%   Algorithm: the compact Michalsky/PSA formulation, accurate to about 0.01
%   degrees over 1950-2050. Far more than adequate here; the NREL SPA would add
%   several hundred lines for no visible difference in annual energy.

latitude  = P.site.latitudeDegreesNorth;
longitude = P.site.longitudeDegreesEast;
utcOffset = P.site.utcOffsetHours;

% Mid-hour, converted to UTC.
midpointLocal = timestamps + minutes(30);
midpointUtc   = midpointLocal - hours(utcOffset);

% Julian day relative to J2000.0
julianDay = juliandate(midpointUtc);
elapsedJulianDays = julianDay - 2451545.0;

% ------------------------------------------------- ecliptic coordinates
omega            = 2.1429 - 0.0010394594 * elapsedJulianDays;
meanLongitude    = 4.8950630 + 0.017202791698 * elapsedJulianDays;
meanAnomaly      = 6.2400600 + 0.017201969700 * elapsedJulianDays;
eclipticLongitude = meanLongitude + 0.03341607 * sin(meanAnomaly) ...
                  + 0.00034894 * sin(2*meanAnomaly) - 0.0001134 ...
                  - 0.0000203 * sin(omega);
eclipticObliquity = 0.4090928 - 6.2140e-9 * elapsedJulianDays ...
                  + 0.0000396 * cos(omega);

% ------------------------------------------------- celestial coordinates
sinEcliptic   = sin(eclipticLongitude);
rightAscension = atan2(cos(eclipticObliquity) .* sinEcliptic, cos(eclipticLongitude));
rightAscension(rightAscension < 0) = rightAscension(rightAscension < 0) + 2*pi;
declination   = asin(sin(eclipticObliquity) .* sinEcliptic);

% ------------------------------------------------- local coordinates
decimalHours = hour(midpointUtc) + minute(midpointUtc)/60 + second(midpointUtc)/3600;
greenwichMeanSiderealTime = 6.6974243242 + 0.0657098283 * elapsedJulianDays + decimalHours;
localMeanSiderealTime = deg2rad(greenwichMeanSiderealTime * 15 + longitude);
hourAngle = localMeanSiderealTime - rightAscension;

latitudeRadians = deg2rad(latitude);
zenith = acos(cos(latitudeRadians) .* cos(hourAngle) .* cos(declination) ...
            + sin(declination) .* sin(latitudeRadians));
azimuth = atan2(-sin(hourAngle), ...
                tan(declination) .* cos(latitudeRadians) - sin(latitudeRadians) .* cos(hourAngle));
azimuth(azimuth < 0) = azimuth(azimuth < 0) + 2*pi;

% Parallax correction (small, but free)
earthMeanRadius   = 6371.01;
astronomicalUnit  = 149597890;
zenith = zenith + (earthMeanRadius / astronomicalUnit) * sin(zenith);

geometry.solarZenithDegrees  = rad2deg(zenith);
geometry.solarAzimuthDegrees = rad2deg(azimuth);
geometry.solarElevationDegrees = 90 - geometry.solarZenithDegrees;

% ------------------------------------------------- extraterrestrial irradiance
dayOfYear = day(midpointUtc, 'dayofyear');
geometry.extraterrestrialDirectNormalWattsPerSquareMetre = ...
    1367.0 * (1 + 0.033 * cos(2*pi*dayOfYear/365));

% ------------------------------------------------- relative air mass (Kasten-Young)
zenithForAirMass = min(geometry.solarZenithDegrees, 90);
geometry.relativeAirMass = 1 ./ (cosd(zenithForAirMass) + ...
    0.50572 * (96.07995 - zenithForAirMass).^(-1.6364));
geometry.relativeAirMass(geometry.solarZenithDegrees >= 90) = NaN;

end
