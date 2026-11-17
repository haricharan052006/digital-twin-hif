function m = relay_window_metrics(W, predCode)
%RELAY_WINDOW_METRICS  Window- and run-level relay metrics for one model.
%
%   m = relay_window_metrics(W, predCode) scores predicted class codes
%   predCode [N x 1] (0 Normal, 1 Switching_Transient, 2/3/4 HIF phase
%   A/B/C) against the windows W, a table with the data/dl/windows.csv
%   columns code, run, lateral, tStart, faulted, adjacent, weak.
%
% Single source of truth for every model of the journal comparison (RF,
% LightGBM, 1D-CNN): each model only writes predictions, and all metrics
% come from here. The run-level part is the open-loop 2-of-3 vote of
% benchmark_noise_robustness.m, unchanged:
%   sequences      each (run, lateral) pair, windows in time order
%                  (one-cycle hop)
%   vote           >= 2 HIF decisions among the last 3 windows
%   dependability  faulted sequence whose FIRST vote falls on a
%                  post-inception (HIF) window; counted over the faulted
%                  sequences with >= 3 HIF windows (eligible)
%   false trip     the first vote of any other sequence, or a faulted
%                  sequence voting on a pre-inception window
%   security       1 - fraction of sequences with a false trip
%
% m fields: Accuracy, MacroF1, PerClassRecall, PerClassPrecision,
% ConfusionMatrix (rows true, cols predicted, order 0..4), HifRecall,
% HifRecallWeak, FalseHifRate, Dependability, DependabilityWeak, Security,
% FalseTrips, FalseTripsAdjacent, FalseTripsNormalSwitching,
% FalseTripsPreInception, Sequences, EligibleSequences, WeakSequences, and
% Seq: the per-sequence outcomes (run, lat675, detected, falseTrip, eligible,
% weak, faulted, adjacent), for run-level bootstrap and subgroup analysis.

yT = W.code(:);
yP = predCode(:);
nC = 5;
C = accumarray([yT yP] + 1, 1, [nC nC]);
tp = diag(C);
prec = tp ./ max(1, sum(C, 1)');
rec  = tp ./ max(1, sum(C, 2));
f1   = 2 * prec .* rec ./ max(eps, prec + rec);

hifT = yT >= 2;
hifP = yP >= 2;
m.Accuracy = mean(yT == yP);
m.MacroF1 = mean(f1);
m.PerClassRecall = rec';
m.PerClassPrecision = prec';
m.ConfusionMatrix = C;
m.HifRecall = mean(hifP(hifT));
m.HifRecallWeak = mean(hifP(hifT & W.weak));
m.FalseHifRate = mean(hifP(~hifT));

% -------------------------------------------------- run-level 2-of-3 vote
latNum = double(string(W.lateral) == "675");
[uq, ~, seq] = unique([W.run, latNum], 'rows');
nS = max(seq);
dep = false(nS, 1);
falseTrip = false(nS, 1);
isFaulted = false(nS, 1);
isAdjacent = false(nS, 1);
isWeak = false(nS, 1);
elig = false(nS, 1);
for q = 1:nS
    idx = find(seq == q);
    [~, o] = sort(W.tStart(idx));
    idx = idx(o);
    isFaulted(q) = W.faulted(idx(1));
    isAdjacent(q) = W.adjacent(idx(1));
    isWeak(q) = W.weak(idx(1));
    elig(q) = isFaulted(q) && nnz(hifT(idx)) >= 3;
    vote = movsum(double(hifP(idx)), [2 0]) >= 2;
    k = find(vote, 1);
    if isempty(k)
        continue;
    end
    if isFaulted(q) && hifT(idx(k))
        dep(q) = true;
    else
        falseTrip(q) = true;
    end
end
m.Dependability = mean(dep(elig));
m.DependabilityWeak = mean(dep(elig & isWeak));
m.Security = 1 - mean(falseTrip);
m.FalseTrips = nnz(falseTrip);
m.FalseTripsAdjacent = nnz(falseTrip & isAdjacent);
m.FalseTripsNormalSwitching = nnz(falseTrip & ~isFaulted & ~isAdjacent);
m.FalseTripsPreInception = nnz(falseTrip & isFaulted);
m.Sequences = nS;
m.EligibleSequences = nnz(elig);
m.WeakSequences = nnz(elig & isWeak);
m.Seq = struct('run', uq(:, 1), 'lat675', uq(:, 2) == 1, 'detected', dep, 'falseTrip', falseTrip, ...
    'eligible', elig, 'weak', isWeak, 'faulted', isFaulted, 'adjacent', isAdjacent);
end
