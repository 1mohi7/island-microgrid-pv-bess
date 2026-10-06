function summary = summariseTrace(gridAvailableFlags, outageCauseCodes, P)
%SUMMARISETRACE  Statistics used to validate sampled traces against the historical one.

unavailable = gridAvailableFlags == 0;
summary.unavailableHours     = sum(unavailable);
summary.unavailabilityPercent = mean(unavailable) * 100;

% Longest continuous run, regardless of cause. This, not the per-cause duration,
% is what the battery and fuel tank have to ride through.
longest = 0; current = 0;
for k = 1:numel(unavailable)
    if unavailable(k); current = current + 1; else; current = 0; end
    longest = max(longest, current);
end
summary.longestContinuousUnavailabilityHours = longest;

names = {'shedding', 'fault', 'maintenance'};
codes = [P.cause.shedding P.cause.fault P.cause.maintenance];
for k = 1:numel(names)
    mask = outageCauseCodes == codes(k);
    summary.([names{k} 'Hours']) = sum(mask);
    durations = runLengths(mask);
    summary.([names{k} 'Events'])          = numel(durations);
    summary.([names{k} 'MeanDurationHours']) = meanOrZero(durations);
    summary.([names{k} 'MaxDurationHours'])  = maxOrZero(durations);
end
end

function d = runLengths(mask)
d = []; current = 0;
for k = 1:numel(mask)
    if mask(k); current = current + 1;
    elseif current > 0; d(end+1) = current; current = 0; end %#ok<AGROW>
end
if current > 0; d(end+1) = current; end
end
function v = meanOrZero(x); if isempty(x); v = 0; else; v = mean(x); end; end
function v = maxOrZero(x);  if isempty(x); v = 0; else; v = max(x);  end; end
