function [gridAvailableFlags, outageCauseCodes] = allHoursAvailableTrace(P)
%ALLHOURSAVAILABLETRACE  The counterfactual the outage-BLIND optimizer is scored against.
%
%   This is what Design A (outage-blind) optimises on: a year in which the grid
%   never fails. Its net present cost from this trace is MEANINGLESS as a
%   headline result and must never be reported as one - see the note in
%   fitnessEvaluate.m. The blind design's sizing is carried over and re-scored on
%   real outage traces for every comparison.

gridAvailableFlags = ones(P.site.hoursPerYear, 1);
outageCauseCodes   = zeros(P.site.hoursPerYear, 1) + P.cause.none;
end
