function statistics = outageModel(inputs, P)
%OUTAGEMODEL  Fit a generative outage sampler to the single historical trace.
%
%   statistics = outageModel(inputs, P)
%
%   Three independent processes, fitted and superimposed:
%     1. Rostered shedding   inhomogeneous Poisson arrivals with a separable
%                            month-by-hour-of-day intensity, empirical duration
%     2. Unplanned faults    homogeneous Poisson arrivals, empirical duration
%     3. Planned maintenance homogeneous Poisson, daytime start, fixed duration
%
%   Faults use a CONSTANT arrival rate, not a seasonal one. Eleven observed
%   events cannot support twelve monthly rates without fitting this particular
%   year's pre-monsoon cluster as though it were structure. Declared choice.
%
%   NON-OVERLAP PLACEMENT AND CALIBRATION. Same-cause events are placed without
%   overlapping OR abutting. Without that rule, two independently sampled
%   one-hour shedding blocks landing in consecutive hours merge into an
%   indistinguishable two-hour block, and since the historical durations were
%   themselves measured as contiguous runs, the inflation compounds on every
%   resample - sampled traces end up containing six-hour shedding events that
%   exist nowhere in the data. Rejection thins the arrival process, which is
%   corrected by intensity multipliers solved by fixed-point moment matching at
%   fit time (typically about 1.16 for shedding, 1.08 for faults).
%
%   THE CLAIRVOYANCE GUARD IS STRUCTURAL. This struct holds NO realised trace.
%   The outage-aware reserve policy reads expectedForeseeableOutageHours, which
%   is computed purely from the fitted intensity and duration distributions. It
%   is not possible for the aware controller to consult the trace it is about to
%   be simulated against, even by mistake.

hoursPerYear = P.site.hoursPerYear;
statistics.monthOfYearByHour = inputs.monthOfYearByHour;
statistics.hourOfDayByHour   = inputs.hourOfDayByHour;
statistics.hoursPerYear      = hoursPerYear;
statistics.cause             = P.cause;

unavailable = inputs.historicalGridAvailableFlags == 0;
events = extractEvents(unavailable, inputs.historicalOutageCauseCodes);

% ------------------------------------------------- shedding intensity
sheddingEvents  = events(events(:,3) == P.cause.shedding, :);
sheddingStarts  = sheddingEvents(:,1);
sheddingDurations = sheddingEvents(:,2);

startsPerMonth     = accumarray(inputs.monthOfYearByHour(sheddingStarts), 1, [12 1]);
startsPerHourOfDay = accumarray(inputs.hourOfDayByHour(sheddingStarts) + 1, 1, [24 1]);
hoursPerMonth      = accumarray(inputs.monthOfYearByHour, 1, [12 1]);
hoursPerHourOfDay  = accumarray(inputs.hourOfDayByHour + 1, 1, [24 1]);

% Marginal-product form: rate(m,h) = [starts(m)/hours(m)] * [starts(h)/hours(h)]
%                                    / [totalStarts / totalHours]
% Reproduces both marginals exactly and assumes month and hour-of-day act
% independently on the intensity.
monthIntensity  = startsPerMonth     ./ max(hoursPerMonth, 1);
hourIntensity   = startsPerHourOfDay ./ max(hoursPerHourOfDay, 1);
overallIntensity = numel(sheddingStarts) / hoursPerYear;
statistics.sheddingIntensityByMonthAndHour = ...
    min(max((monthIntensity * hourIntensity') / overallIntensity, 0), 1);

[statistics.sheddingDurationValues, statistics.sheddingDurationProbabilities] = ...
    empiricalDistribution(sheddingDurations);

% ------------------------------------------------- faults
faultEvents = events(events(:,3) == P.cause.fault, :);
statistics.faultArrivalRatePerHour = size(faultEvents, 1) / hoursPerYear;
[statistics.faultDurationValues, statistics.faultDurationProbabilities] = ...
    empiricalDistribution(faultEvents(:,2));

% ------------------------------------------------- maintenance
maintenanceEvents = events(events(:,3) == P.cause.maintenance, :);
statistics.maintenanceArrivalRatePerHour = size(maintenanceEvents, 1) / hoursPerYear;
if isempty(maintenanceEvents)
    statistics.maintenanceDurationHours = 7;
    statistics.maintenanceEarliestStartHourOfDay = 8;
    statistics.maintenanceLatestStartHourOfDay   = 10;
else
    statistics.maintenanceDurationHours = round(median(maintenanceEvents(:,2)));
    startHours = inputs.hourOfDayByHour(maintenanceEvents(:,1));
    statistics.maintenanceEarliestStartHourOfDay = min(startHours);
    statistics.maintenanceLatestStartHourOfDay   = max(startHours);
end

% ------------------------------------------------- calibrate out the thinning
statistics.sheddingIntensityCalibrationFactor = 1.0;
statistics.faultIntensityCalibrationFactor    = 1.0;
targetSheddingHours = sum(inputs.historicalOutageCauseCodes == P.cause.shedding);
targetFaultHours    = sum(inputs.historicalOutageCauseCodes == P.cause.fault);

numberOfCalibrationTraces = 40;
for iteration = 1:6
    sheddingHours = zeros(numberOfCalibrationTraces, 1);
    faultHours    = zeros(numberOfCalibrationTraces, 1);
    for traceIndex = 1:numberOfCalibrationTraces
        [~, causes] = sampleOutageTrace(statistics, 900000 + traceIndex, P);
        sheddingHours(traceIndex) = sum(causes == P.cause.shedding);
        faultHours(traceIndex)    = sum(causes == P.cause.fault);
    end
    statistics.sheddingIntensityCalibrationFactor = ...
        statistics.sheddingIntensityCalibrationFactor * ...
        targetSheddingHours / max(mean(sheddingHours), 1e-6);
    statistics.faultIntensityCalibrationFactor = ...
        statistics.faultIntensityCalibrationFactor * ...
        targetFaultHours / max(mean(faultHours), 1e-6);
end

end

% =====================================================================
function events = extractEvents(unavailableFlags, causeCodes)
%EXTRACTEVENTS  [startHour, durationHours, causeCode] per event.
%
%   Runs are segmented on BOTH availability and cause. A fault beginning in the
%   hour a shedding block ends is two events, not one six-hour shedding event.
%   Segmenting only on availability would mislabel the cause of the merged tail
%   and inflate the shedding duration distribution, which then feeds straight
%   back into the sampler on refit.

events = zeros(0, 3);
hourIndex = 1;
numberOfHours = numel(unavailableFlags);
while hourIndex <= numberOfHours
    if unavailableFlags(hourIndex)
        causeCode = causeCodes(hourIndex);
        blockEnd = hourIndex;
        while blockEnd <= numberOfHours && unavailableFlags(blockEnd) && ...
              causeCodes(blockEnd) == causeCode
            blockEnd = blockEnd + 1;
        end
        events(end+1, :) = [hourIndex, blockEnd - hourIndex, causeCode]; %#ok<AGROW>
        hourIndex = blockEnd;
    else
        hourIndex = hourIndex + 1;
    end
end
end

% =====================================================================
function [values, probabilities] = empiricalDistribution(samples)
if isempty(samples)
    values = 1; probabilities = 1; return;
end
values = unique(samples(:))';
counts = histcounts(samples, [values, max(values)+1]);
probabilities = counts / sum(counts);
end
