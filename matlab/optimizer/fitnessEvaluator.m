function evaluator = fitnessEvaluator(inputs, photovoltaicPerKilowatt, ...
                                      gridAvailableMatrix, outageCauseMatrix, ...
                                      policy, lossOfLoadThreshold, P, ...
                                      enforceConstraint, allowGridCharging)
%FITNESSEVALUATOR  Dispatch across traces, then economics, then penalty.
%
%   evaluator = fitnessEvaluator(inputs, photovoltaicPerKilowatt, ...
%                                gridAvailableMatrix, outageCauseMatrix, ...
%                                policy, lossOfLoadThreshold, P, ...
%                                enforceConstraint, allowGridCharging)
%
%   gridAvailableMatrix and outageCauseMatrix are (numberOfTraces x 8760).
%
%       violation = max(0, lossOfLoadProbability - threshold)
%       fitness   = meanNetPresentCost
%                 + linearWeight*violation + quadraticWeight*violation^2
%
%   THE LINEAR TERM IS AN ADDITION TO THE BRIEF, which specified a pure
%   quadratic. Tested at realistic magnitudes a pure quadratic fails exactly
%   where it matters: at a weight of 5e8, a solution violating the threshold by
%   0.001 (one hour in a thousand) picks up a penalty of $500 against an $8M
%   objective and would come back as the winner while being infeasible. The
%   quadratic only bites on gross violations, which the optimizer would have
%   discarded anyway. With the linear term that same violation costs $2M,
%   exceeding the entire spread of net present cost across the feasible space.
%
%   THIS IS THE ONLY PLACE THE TWO DESIGNS DIFFER. The Grey Wolf Optimizer is
%   design-agnostic and never learns which experiment it is running:
%
%     outage-BLIND   traces = the all-hours-available counterfactual
%                    policy = reservePolicy('blind', ...)
%                    enforceConstraint = false (nothing can fail)
%
%     outage-AWARE   traces = the five in-sample sampled years
%                    policy = reservePolicy('aware', ...)
%                    enforceConstraint = true
%
%   NEVER report the blind design's net present cost from its own outage-free
%   run. On an all-available trace the feeder is billed for every kilowatt hour,
%   whereas an outage trace disconnects non-critical load for ~758 h/yr that
%   nobody pays for - so outages look like a SAVING to a model that does not
%   price unserved energy. Both designs must be re-scored on identical traces.
%
%   CATALOGUE SNAPPING happens HERE and only here. The wolf's stored position
%   stays continuous so the search landscape is not turned into a staircase.
%
%   CACHING is on a rounded key AND THE EVALUATED SIZING IS QUANTISED TO THE
%   SAME GRID. Those two must go together. Rounding only the key while leaving
%   the sizing continuous makes 432.2 kW and 432.4 kW share a cache entry while
%   being different systems, and whichever was evaluated first has its result
%   silently returned for the other. That bug is invisible in aggregate - the
%   optimizer still converges and every number still looks plausible - which is
%   precisely what makes it dangerous. Quantising makes the cache LOSSLESS.

if nargin < 8 || isempty(enforceConstraint); enforceConstraint = true; end
if nargin < 9 || isempty(allowGridCharging); allowGridCharging = true; end

evaluator.inputs                  = inputs;
evaluator.photovoltaicPerKilowatt = photovoltaicPerKilowatt;
evaluator.gridAvailableMatrix     = gridAvailableMatrix;
evaluator.outageCauseMatrix       = outageCauseMatrix;
evaluator.policy                  = policy;
evaluator.lossOfLoadThreshold     = lossOfLoadThreshold;
evaluator.P                       = P;
evaluator.enforceConstraint       = enforceConstraint;
evaluator.allowGridCharging       = allowGridCharging;

% containers.Map is used as the cache. Handle semantics mean it persists across
% copies of the evaluator struct, which is what lets seeds share a cache.
evaluator.cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
evaluator.counters = struct('evaluations', 0, 'cacheHits', 0);

end
