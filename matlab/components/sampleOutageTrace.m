function [gridAvailableFlags, outageCauseCodes] = sampleOutageTrace(statistics, randomSeed, P)
%SAMPLEOUTAGETRACE  Draw one synthetic year from the fitted outage model.
%
%   [gridAvailableFlags, outageCauseCodes] = sampleOutageTrace(statistics, seed, P)
%
%   Same-cause events are placed WITHOUT overlapping or abutting; see the note
%   in outageModel.m for why. Different causes MAY overlap. Cause priority is
%   fault > maintenance > shedding, so an hour that is both rostered and faulted
%   is reported as a fault. Under-reporting shedding this way is conservative:
%   it stops the forewarning variant claiming credit for hours no roster foresaw.

hoursPerYear = statistics.hoursPerYear;
generator = RandStream('mt19937ar', 'Seed', randomSeed);

outageCauseCodes  = zeros(hoursPerYear, 1);
sheddingOccupied  = false(hoursPerYear, 1);
faultOccupied     = false(hoursPerYear, 1);
maintenanceOccupied = false(hoursPerYear, 1);

% AUDIT FIX (item 2): explicit priority, fault > maintenance > shedding, as the
% header promises. The numeric codes (shedding=1, fault=2, maintenance=3) are
% labels, not ranks, so max(code) let maintenance overwrite a fault.
priorityRank = zeros(1, 4);                 % indexed by code + 1; none = 0
priorityRank(P.cause.shedding    + 1) = 1;
priorityRank(P.cause.maintenance + 1) = 2;
priorityRank(P.cause.fault       + 1) = 3;

% ------------------------------------------------------------ shedding
linearIndex = sub2ind([12 24], statistics.monthOfYearByHour, statistics.hourOfDayByHour + 1);
intensityByHour = statistics.sheddingIntensityByMonthAndHour(linearIndex) * ...
                  statistics.sheddingIntensityCalibrationFactor;
candidateStarts = find(rand(generator, hoursPerYear, 1) < intensityByHour(:));
candidateDurations = drawFrom(generator, statistics.sheddingDurationValues, ...
                              statistics.sheddingDurationProbabilities, numel(candidateStarts));
for k = 1:numel(candidateStarts)
    [outageCauseCodes, sheddingOccupied] = placeEvent(outageCauseCodes, sheddingOccupied, ...
        candidateStarts(k), candidateDurations(k), P.cause.shedding, hoursPerYear, priorityRank);
end

% ------------------------------------------------------------ faults
faultRate = statistics.faultArrivalRatePerHour * statistics.faultIntensityCalibrationFactor;
candidateStarts = find(rand(generator, hoursPerYear, 1) < faultRate);
candidateDurations = drawFrom(generator, statistics.faultDurationValues, ...
                              statistics.faultDurationProbabilities, numel(candidateStarts));
for k = 1:numel(candidateStarts)
    [outageCauseCodes, faultOccupied] = placeEvent(outageCauseCodes, faultOccupied, ...
        candidateStarts(k), candidateDurations(k), P.cause.fault, hoursPerYear, priorityRank);
end

% ------------------------------------------------------------ maintenance
eligible = statistics.hourOfDayByHour >= statistics.maintenanceEarliestStartHourOfDay & ...
           statistics.hourOfDayByHour <= statistics.maintenanceLatestStartHourOfDay;
maintenanceRate = statistics.maintenanceArrivalRatePerHour * hoursPerYear / max(sum(eligible), 1);
candidateStarts = find(eligible(:) & rand(generator, hoursPerYear, 1) < maintenanceRate);
for k = 1:numel(candidateStarts)
    [outageCauseCodes, maintenanceOccupied] = placeEvent(outageCauseCodes, maintenanceOccupied, ...
        candidateStarts(k), statistics.maintenanceDurationHours, P.cause.maintenance, hoursPerYear, priorityRank);
end

gridAvailableFlags = double(outageCauseCodes == P.cause.none);

end

% =====================================================================
function [causeCodes, occupancy] = placeEvent(causeCodes, occupancy, startHour, ...
                                              durationHours, causeCode, hoursPerYear, priorityRank)
% Place only if the event neither overlaps nor abuts an existing same-cause one.
guardStart = max(startHour - 1, 1);
guardEnd   = min(startHour + durationHours, hoursPerYear);
if any(occupancy(guardStart:guardEnd))
    return;
end
endHour = min(startHour + durationHours - 1, hoursPerYear);
occupancy(startHour:endHour) = true;
segment = causeCodes(startHour:endHour);
overwrite = priorityRank(causeCode + 1) > priorityRank(segment + 1);
segment(overwrite) = causeCode;
causeCodes(startHour:endHour) = segment;
end

% =====================================================================
function draws = drawFrom(generator, values, probabilities, count)
if count == 0; draws = []; return; end
edges = [0 cumsum(probabilities(:)')];
edges(end) = 1;
[~, bins] = histc(rand(generator, count, 1), edges); %#ok<HISTC>
bins = max(min(bins, numel(values)), 1);
draws = values(bins);
end
