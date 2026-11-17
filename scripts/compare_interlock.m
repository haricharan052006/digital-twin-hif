function C = compare_interlock()
%COMPARE_INTERLOCK  Closed-loop study with vs without the inter-relay
% interlock (benchmark_clearing_times.m with interlock false / true), run
% for run: same relay, case, breaker time and inception instant.
%
%   C = compare_interlock() returns, per relay x breaker time over the 32 HIF
%   runs: faults cleared, healthy-lateral trips (sympathetic) without and
%   with the interlock, raw sympathetic latches the interlock blocked, median
%   clearing time without / with, and the largest change of the faulted
%   lateral's trip time and clearing time. Also checks the decoy runs.
% Writes results/dl/interlock_comparison.csv.

projectRoot = fileparts(fileparts(mfilename('fullpath')));
resDir = fullfile(projectRoot, 'results', 'dl');
A = readRuns(fullfile(resDir, 'clearing_times.csv'));
B = readRuns(fullfile(resDir, 'clearing_times_interlock.csv'));
key = @(T) T.relay + "|" + T.caseName + "|" + string(T.delayCycles) + "|" + string(T.offset_ms);
[~, ia, ib] = intersect(key(A), key(B));
A = A(ia, :);
B = B(ib, :);
fprintf('%d runs matched\n', height(A));

H = A.scenario == "hif";
rows = {};
for m = ["RF", "LightGBM", "CNN wide"]
    for d = [0 3 5]
        s = H & A.relay == m & A.delayCycles == d;
        okA = s & ~A.missed & ~A.preInception;
        okB = s & ~B.missed & ~B.preInception;
        rows(end + 1, :) = {m, d, nnz(s), nnz(okA), nnz(okB), nnz(s & A.sympathetic), nnz(s & B.sympathetic), ...
            nnz(s & B.rawSympathetic & ~B.sympathetic), median(A.clearing_ms(s), 'omitnan'), ...
            median(B.clearing_ms(s), 'omitnan'), max(abs(A.trip_ms(s) - B.trip_ms(s)), [], 'omitnan'), ...
            max(abs(A.clearing_ms(s) - B.clearing_ms(s)), [], 'omitnan')}; %#ok<AGROW>
    end
end
C = cell2table(rows, 'VariableNames', {'Relay', 'BreakerCycles', 'HifRuns', 'ClearedOff', 'ClearedOn', ...
    'SympatheticOff', 'SympatheticOn', 'BlockedLatches', 'ClearingMedianOff_ms', 'ClearingMedianOn_ms', ...
    'MaxTripChange_ms', 'MaxClearingChange_ms'});
writetable(C, fullfile(resDir, 'interlock_comparison.csv'));
disp(C);
D = B(~H, :);
fprintf('Decoy runs with the interlock: %d, with any trip: %d\n', height(D), nnz(D.tripped ~= "none"));
fprintf('HIF runs whose faulted-lateral trip time changed: %d\n', nnz(H & abs(A.trip_ms - B.trip_ms) > 1e-9));
end

%% ======================================================================
function T = readRuns(f)
opts = detectImportOptions(f);
txt = intersect(opts.VariableNames, {'scenario', 'bus', 'phase', 'tripped', 'relay', 'caseName', 'missed', ...
    'sympathetic', 'rawSympathetic', 'preInception', 'interlock'});
opts = setvartype(opts, txt, 'string');
T = readtable(f, opts);
for v = intersect(T.Properties.VariableNames, {'missed', 'sympathetic', 'rawSympathetic', 'preInception'})
    T.(v{1}) = T.(v{1}) == "true" | T.(v{1}) == "1";
end
if ~ismember('rawSympathetic', T.Properties.VariableNames)
    T.rawSympathetic = T.sympathetic;   % runs made before the interlock existed
end
end
