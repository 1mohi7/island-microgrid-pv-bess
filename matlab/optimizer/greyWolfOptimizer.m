function [result, evaluator] = greyWolfOptimizer(evaluator, lowerBounds, upperBounds, ...
                                                  populationSize, maximumIterations, seed)
%GREYWOLFOPTIMIZER  Plain canonical Grey Wolf Optimizer.
%
%   [result, evaluator] = greyWolfOptimizer(evaluator, lowerBounds, upperBounds, ...
%                                           populationSize, maximumIterations, seed)
%
%   THE EVALUATOR COMES BACK AS A SECOND, SEPARATE OUTPUT - NOT AS A FIELD OF
%   result - and this is not cosmetic. evaluator.cache is a containers.Map that
%   grows by one entry per fitness call and is never cleared between seeds, so
%   that later seeds benefit from earlier ones' work. If it were folded into
%   result (as result.evaluator = evaluator), every saved run would carry the
%   entire accumulated cache - thousands of heterogeneous struct entries, each
%   with its own type metadata under -v7.3 (HDF5) - and a 24-run save (12 seeds
%   x 2 designs) balloons past half a gigabyte from a results struct that should
%   be a few megabytes. Use the second output only to thread the cache forward
%   between seeds in a LOCAL variable; never assign it into anything you save.
%
%   Population of wolves, each a position vector in the four decision variables.
%   Each iteration: evaluate fitness, identify alpha, beta and delta (the three
%   best), and move every wolf toward the mean of the three encircling
%   estimates, with the control parameter `a` decreasing linearly from 2 to 0.
%
%       a = 2 - 2*iteration/maximumIterations
%       A = 2*a*r1 - a                r1, r2 ~ U(0,1), drawn PER DIMENSION
%       C = 2*r2
%       D_leader = | C*X_leader - X |
%       X_leader_estimate = X_leader - A*D_leader
%       X_next = mean of the three leader estimates
%
%   NO MODIFIED OR HYBRID VARIANT. Reaching for a chaotic-initialisation,
%   levy-flight or opposition-based variant before plain Grey Wolf has been
%   SHOWN to underperform invites the reviewer to ask whether the algorithm is
%   doing the work rather than the model. The convergence study establishes that
%   plain Grey Wolf converges here: every population size from 10 to 50 reaches
%   the same optimum, with a standard deviation across all runs of about 1e-5 of
%   the objective. There is no defensible case for a variant.
%
%   THE OPTIMIZER IS DESIGN-AGNOSTIC. It receives an evaluator and never learns
%   whether it is running the outage-blind or outage-aware experiment. All the
%   difference lives in the evaluator. If this file ever needs an
%   `if design == ...` branch, the experiment has stopped isolating the thing it
%   claims to isolate.
%
%   Boundary handling is CLIPPING, applied consistently. Reflection was
%   considered and rejected as no better here and harder to reason about.
%
%   The BEST FEASIBLE solution is tracked alongside the best-fitness solution.
%   The penalty should make these the same, but the brief is explicit that the
%   winner's feasibility must be VERIFIED rather than assumed, and a solution
%   that is merely cheap must never be reported as a winner.

lowerBounds = lowerBounds(:)';
upperBounds = upperBounds(:)';
dimensions  = numel(lowerBounds);

randomStream = RandStream('mt19937ar', 'Seed', seed);

positions = repmat(lowerBounds, populationSize, 1) + ...
            rand(randomStream, populationSize, dimensions) .* ...
            repmat(upperBounds - lowerBounds, populationSize, 1);

alphaPosition = zeros(1, dimensions); alphaFitness = Inf;
betaPosition  = zeros(1, dimensions); betaFitness  = Inf;
deltaPosition = zeros(1, dimensions); deltaFitness = Inf;

bestFeasiblePosition = [];
bestFeasibleFitness  = Inf;

bestHistory        = zeros(maximumIterations, 1);
evaluationHistory  = zeros(maximumIterations, 1);
alphaHistory       = zeros(maximumIterations, dimensions);
spreadHistory      = zeros(maximumIterations, 1);
evaluations = 0;

for iteration = 1:maximumIterations

    % ---- evaluate and rank ------------------------------------------
    for wolfIndex = 1:populationSize
        [fitness, outcome, evaluator] = evaluateFitness(evaluator, positions(wolfIndex, :));
        evaluations = evaluations + 1;

        if outcome.isFeasible && fitness < bestFeasibleFitness
            bestFeasibleFitness  = fitness;
            bestFeasiblePosition = positions(wolfIndex, :);
        end

        if fitness < alphaFitness
            deltaFitness = betaFitness;  deltaPosition = betaPosition;
            betaFitness  = alphaFitness; betaPosition  = alphaPosition;
            alphaFitness = fitness;      alphaPosition = positions(wolfIndex, :);
        elseif fitness < betaFitness
            deltaFitness = betaFitness;  deltaPosition = betaPosition;
            betaFitness  = fitness;      betaPosition  = positions(wolfIndex, :);
        elseif fitness < deltaFitness
            deltaFitness = fitness;      deltaPosition = positions(wolfIndex, :);
        end
    end

    bestHistory(iteration)       = alphaFitness;
    evaluationHistory(iteration) = evaluations;
    alphaHistory(iteration, :)   = alphaPosition;
    spreadHistory(iteration)     = mean(std(positions, 0, 1));

    % ---- move the pack ------------------------------------------------
    controlParameter = 2.0 - 2.0 * (iteration - 1) / maximumIterations;

    leaders = [alphaPosition; betaPosition; deltaPosition];
    estimates = zeros(3, populationSize, dimensions);
    for leaderIndex = 1:3
        leaderPosition = repmat(leaders(leaderIndex, :), populationSize, 1);
        randomA = rand(randomStream, populationSize, dimensions);
        randomC = rand(randomStream, populationSize, dimensions);
        coefficientA = 2 * controlParameter * randomA - controlParameter;
        coefficientC = 2 * randomC;
        distance = abs(coefficientC .* leaderPosition - positions);
        estimates(leaderIndex, :, :) = leaderPosition - coefficientA .* distance;
    end

    positions = squeeze(mean(estimates, 1));
    if dimensions == 1; positions = positions(:); end

    positions = min(max(positions, repmat(lowerBounds, populationSize, 1)), ...
                                   repmat(upperBounds, populationSize, 1));
end

result.bestPosition          = alphaPosition;
result.bestFitness           = alphaFitness;
result.bestFeasiblePosition  = bestFeasiblePosition;
result.bestFeasibleFitness   = bestFeasibleFitness;
result.convergenceHistoryBestFitness = bestHistory;
result.convergenceHistoryEvaluations = evaluationHistory;
result.alphaPositionHistory  = alphaHistory;
result.swarmSpreadHistory    = spreadHistory;
result.seed                  = seed;
result.populationSize        = populationSize;
result.iterations            = maximumIterations;
% Lightweight counters only - two integers, not the evaluator itself. If you
% need the cache hit rate after the run, read it from the SECOND output
% (the live evaluator), not from anything stored in result.
result.evaluationCount       = evaluator.counters.evaluations;
result.cacheHitCount         = evaluator.counters.cacheHits;

% Iteration after which the best-so-far never improves again. This is the
% number that justifies an iteration budget: running past it buys nothing,
% stopping before it means the search was still moving.
improvements = find(diff(bestHistory) < -1e-9);
if isempty(improvements)
    result.iterationOfLastImprovement = 0;
else
    result.iterationOfLastImprovement = improvements(end) + 1;
end

totalGain = bestHistory(1) - bestHistory(end);
if totalGain <= 0
    result.iterationReaching99PercentOfGain = 0;
else
    target = bestHistory(1) - 0.99 * totalGain;
    result.iterationReaching99PercentOfGain = find(bestHistory <= target, 1, 'first');
end

end
