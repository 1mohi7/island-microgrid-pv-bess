function [criticalLoadKW, facilityBreakdown] = compute_critical_load(config, calendarData)
%COMPUTE_CRITICAL_LOAD  Hourly critical-load time series in kW.
%
%   [criticalLoadKW, facilityBreakdown] = compute_critical_load(config, calendarData)
%
%   criticalLoadKW    : (24*numberOfDays) x 1 total critical demand in kW
%   facilityBreakdown : struct with one field per facility, each an
%                       (24*numberOfDays) x 1 vector in kW - used for
%                       auditing which facilities dominate at each hour.
%
%   Reads config.critical - a struct array where every entry declares
%     .name          text label
%     .peakKW        rated peak in kW
%     .weekdayShape  24 x 1 vector of fractions of peak, index 1 = 00:00
%     .dayOverrides  optional struct keyed by three-letter day name
%                    (Sun,Mon,...,Sat) with per-day 24 x 1 shape overrides
%
%   Result is deterministic: no noise, no temperature coupling. Critical
%   equipment is assumed to run on its schedule regardless of weather. If a
%   facility should scale with temperature (rare - most safety-critical
%   loads are climate-hardened and thermostat-controlled), model it as an
%   overlay in the main config.overlay array instead.

if ~isfield(config, 'critical') || isempty(config.critical)
    criticalLoadKW    = zeros(24 * calendarData.numberOfDays, 1);
    facilityBreakdown = struct();
    return
end

numberOfDays  = calendarData.numberOfDays;
numberOfHours = 24 * numberOfDays;
criticalLoadKW    = zeros(numberOfHours, 1);
facilityBreakdown = struct();

for facilityIndex = 1:numel(config.critical)
    facility = config.critical(facilityIndex);

    % Validation
    if ~isfield(facility,'weekdayShape') || numel(facility.weekdayShape) ~= 24
        error('Critical facility "%s": weekdayShape must contain 24 elements.', ...
              facility.name);
    end
    if ~isfield(facility,'peakKW') || facility.peakKW < 0
        error('Critical facility "%s": peakKW must be a non-negative scalar.', ...
              facility.name);
    end

    defaultShape = facility.weekdayShape(:);

    % Build the 24 x numberOfDays load matrix, applying per-day overrides
    facilityLoadMatrix = repmat(defaultShape, 1, numberOfDays);
    if isfield(facility, 'dayOverrides') && ~isempty(facility.dayOverrides)
        overrideDayNames = fieldnames(facility.dayOverrides);
        for overrideIndex = 1:numel(overrideDayNames)
            thisDayName        = overrideDayNames{overrideIndex};
            thisOverrideShape  = facility.dayOverrides.(thisDayName)(:);
            if numel(thisOverrideShape) ~= 24
                error(['Critical facility "%s": dayOverrides.%s must ' ...
                       'contain 24 elements.'], facility.name, thisDayName);
            end
            selectedDays = strcmp(calendarData.dayName, thisDayName);
            facilityLoadMatrix(:, selectedDays) = ...
                repmat(thisOverrideShape, 1, sum(selectedDays));
        end
    end

    facilityLoadKW  = facility.peakKW * facilityLoadMatrix(:);
    criticalLoadKW  = criticalLoadKW + facilityLoadKW;

    safeFieldName   = matlab.lang.makeValidName(facility.name);
    facilityBreakdown.(safeFieldName) = facilityLoadKW;
end
end
