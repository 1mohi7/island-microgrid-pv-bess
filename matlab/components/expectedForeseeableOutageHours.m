function expectedHours = expectedForeseeableOutageHours(statistics, horizonHours, P)
%EXPECTEDFORESEEABLEOUTAGEHOURS  Forward-looking statistic for the aware policy.
%
%   expectedHours = expectedForeseeableOutageHours(statistics, horizonHours, P)
%
%   Expected number of FORESEEABLE outage hours in the next horizonHours, for
%   each hour of the year, computed purely from the fitted intensity and
%   duration distributions evaluated at that hour's (month, hour-of-day)
%   coordinates. NO REALISED TRACE IS CONSULTED ANYWHERE IN THIS FUNCTION.
%
%   Faults are EXCLUDED because they are unforeseeable by construction.
%   Including them would let the aware controller hold reserve against events no
%   real operator could anticipate. Their contribution shows up instead as the
%   residual unserved energy that separates shedding from fault in the results.
%
%   The rolling forward sum wraps at year end, so the last hours of December
%   look ahead into January rather than seeing nothing.

hoursPerYear = statistics.hoursPerYear;

meanSheddingDuration = sum(statistics.sheddingDurationValues .* ...
                           statistics.sheddingDurationProbabilities);
meanMaintenanceDuration = statistics.maintenanceDurationHours;

linearIndex = sub2ind([12 24], statistics.monthOfYearByHour, statistics.hourOfDayByHour + 1);
sheddingIntensity = statistics.sheddingIntensityByMonthAndHour(linearIndex) * ...
                    statistics.sheddingIntensityCalibrationFactor;
sheddingIntensity = sheddingIntensity(:);

eligible = statistics.hourOfDayByHour >= statistics.maintenanceEarliestStartHourOfDay & ...
           statistics.hourOfDayByHour <= statistics.maintenanceLatestStartHourOfDay;
maintenanceIntensity = zeros(hoursPerYear, 1);
maintenanceIntensity(eligible) = statistics.maintenanceArrivalRatePerHour * ...
                                 hoursPerYear / max(sum(eligible), 1);

perHour = sheddingIntensity * meanSheddingDuration + ...
          maintenanceIntensity * meanMaintenanceDuration;

padded = [perHour; perHour(1:horizonHours)];
cumulative = [0; cumsum(padded)];
expectedHours = cumulative(horizonHours+1 : horizonHours+hoursPerYear) - ...
                cumulative(1:hoursPerYear);
end
