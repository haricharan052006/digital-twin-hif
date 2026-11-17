%% benchmark_noise_robustness.m
% Measurement-noise robustness of the in-model HIF relay (current pipeline:
% lateral-head residual windows, 87 db4 features, 100-tree Random Forest).
%
% For every HELD-OUT test run of train_classifiers.m (grouped split) the
% two-cycle windows of data/features.mat are re-cut from the raw lateral
% residuals (data/raw_residuals*.mat). White Gaussian noise with a fixed
% absolute standard deviation sigma (A) is added to each phase - a CT /
% acquisition noise floor on the physical measurement; the twin is noise
% free, so the noise appears 1:1 in the residual dI = I_phys - I_twin. The
% windows are then classified exactly as HIFRelayBlock.m does
% (hif_window_features -> z-score with the training scaler -> Random
% Forest; predict() and rf_predict_flat return identical labels).
%
% Reported per sigma:
%   window level - accuracy, HIF recall (any HIF phase), false-HIF rate
%                  (non-HIF windows classified as HIF)
%   run level    - the relay's 2-of-3 vote applied to each lateral's
%                  consecutive windows (one-cycle hop; the in-model relay
%                  votes every half cycle). This is an OPEN-LOOP check: the
%                  dataset runs never clear the fault, so a relay keeps
%                  seeing an uncleared arc until the end of the 0.3 s run.
%                  dependability = faulted lateral of an HIF run trips on a
%                                  post-inception window; counted over the
%                                  sequences with >= 3 post-inception
%                                  windows (late inceptions leave too few
%                                  windows for any 2-of-3 decision)
%                  false trips   = a 2-of-3 HIF vote anywhere else, split
%                                  into: adjacent lateral during an HIF on
%                                  the other lateral (sympathetic), Normal
%                                  or switching runs, and pre-inception
%                                  windows of the faulted lateral
% sigma = 0 must reproduce the stored training features bit for bit
% (checked below), so the benchmark measures noise and nothing else.
%
% Outputs: results/noise_robustness_relay.csv,
%          results/report_figures/fig_noise_robustness.png
% Requires: Wavelet Toolbox, Statistics and Machine Learning Toolbox.

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);
SIGMAS = [0 0.005 0.01 0.02 0.05 0.1 0.2 0.5];   % A, per phase
RNG_SEED = 2026;

F = load(fullfile(projectRoot, 'data', 'features.mat'), 'X', 'y', 'runIdx', 'runSource', 'lateral', 'tStart', 'WINDOW_LEN');
T = load(fullfile(projectRoot, 'models', 'trained_classifiers.mat'), 'results');
Bnd = load(fullfile(projectRoot, 'models', 'hif_relay_model.mat'), 'relayModel', 'scaler', 'classNames', 'windowLen');
assert(Bnd.windowLen == F.WINDOW_LEN, 'Relay window length differs from the feature windows.');
W = F.WINDOW_LEN;

S = load(fullfile(projectRoot, 'data', 'raw_residuals.mat'), 'dI633L', 'dI675L', 'tGrid', 'meta');
Bd = load(fullfile(projectRoot, 'data', 'raw_residuals_boundary.mat'), 'dI633L', 'dI675L', 'meta');
res = {cat(3, S.dI633L, Bd.dI633L), cat(3, S.dI675L, Bd.dI675L)};
meta = [S.meta(:); Bd.meta(:)];
tGrid = S.tGrid;
clear S Bd

test = find(ismember(F.runIdx, T.results.testRuns));
nT = numel(test);
[~, s0] = ismember(F.tStart(test), tGrid);
latIdx = double(F.lateral(test) == '675') + 1;
yTrue = F.y(test);
isHifTrue = startsWith(string(yTrue), 'HIF');
fprintf('Held-out test set: %d windows from %d runs\n', nT, numel(unique(F.runIdx(test))));

% run/lateral sequences for the vote
pairKey = F.runIdx(test) * 10 + latIdx;
[pairs, ~, pairOf] = unique(pairKey);
pairRun = floor(pairs / 10);
pairLat = mod(pairs, 10);
latTags = {'633', '675'};
pairFaulted = false(numel(pairs), 1);
pairWeak = false(numel(pairs), 1);
pairAdjacent = false(numel(pairs), 1);   % healthy lateral of an HIF run
pairElig = false(numel(pairs), 1);       % faulted, >= 3 post-inception windows
for q = 1:numel(pairs)
    m = meta(pairRun(q));
    pairFaulted(q) = strcmp(m.type, 'HIF') && strcmp(m.bus, latTags{pairLat(q)});
    pairAdjacent(q) = strcmp(m.type, 'HIF') && ~pairFaulted(q);
    src = string(F.runSource(find(F.runIdx == pairRun(q), 1)));
    pairWeak(q) = pairFaulted(q) && src == "boundary";
    pairElig(q) = pairFaulted(q) && nnz(isHifTrue(pairOf == q)) >= 3;
end
fprintf('%d run/lateral sequences: %d faulted (%d with >= 3 post-inception windows, %d of them weak), %d adjacent, %d in Normal / switching runs\n', ...
    numel(pairs), nnz(pairFaulted), nnz(pairElig), nnz(pairElig & pairWeak), nnz(pairAdjacent), nnz(~pairFaulted & ~pairAdjacent));

rows = zeros(numel(SIGMAS), 13);
for i = 1:numel(SIGMAS)
    sigma = SIGMAS(i);
    rng(RNG_SEED + i);
    Xn = zeros(nT, size(F.X, 2));
    for r = 1:nT
        seg = double(res{latIdx(r)}(s0(r):s0(r) + W - 1, :, F.runIdx(test(r))));
        if sigma > 0
            seg = seg + sigma * randn(W, 3);
        end
        Xn(r, :) = hif_window_features(seg);
    end
    if sigma == 0
        dev = max(abs(Xn - F.X(test, :)), [], 'all');
        fprintf('  sigma = 0 reproduces the stored features: max |diff| = %g\n', dev);
        assert(dev == 0, 'Re-cut windows do not reproduce features.mat.');
    end
    Z = (Xn - Bnd.scaler.mu) ./ Bnd.scaler.sigma;
    yPred = string(predict(Bnd.relayModel, Z));
    isHifPred = startsWith(yPred, 'HIF');
    acc = mean(yPred == string(yTrue));
    hifRecall = mean(isHifPred(isHifTrue));
    falseHif = mean(isHifPred(~isHifTrue));

    % run level 2-of-3 vote over each lateral's consecutive windows
    dep = false(numel(pairs), 1);
    falseTrip = false(numel(pairs), 1);
    for q = 1:numel(pairs)
        idx = find(pairOf == q);
        [~, o] = sort(F.tStart(test(idx)));
        idx = idx(o);
        vote = movsum(double(isHifPred(idx)), [2 0]) >= 2;
        k = find(vote, 1);
        if isempty(k)
            continue;
        end
        if pairFaulted(q) && isHifTrue(idx(k))
            dep(q) = true;
        else
            falseTrip(q) = true;
        end
    end
    rows(i, :) = [sigma, 20 * log10(64.7 / max(sigma, eps)), acc, hifRecall, falseHif, ...
        mean(dep(pairElig)), mean(dep(pairElig & pairWeak)), 1 - mean(falseTrip), ...
        nnz(falseTrip), nnz(falseTrip & pairAdjacent), nnz(falseTrip & ~pairFaulted & ~pairAdjacent), ...
        nnz(falseTrip & pairFaulted), numel(pairs)];
    fprintf(['  sigma %.3f A: window acc %.2f %%, HIF recall %.2f %%, false-HIF %.2f %% | ' ...
        'dependability %.1f %% (weak %.1f %%) | false trips %d of %d (adjacent %d, Normal/switching runs %d, pre-inception %d)\n'], ...
        sigma, 100 * acc, 100 * hifRecall, 100 * falseHif, 100 * rows(i, 6), 100 * rows(i, 7), ...
        rows(i, 9), numel(pairs), rows(i, 10), rows(i, 11), rows(i, 12));
end

Tab = array2table(rows, 'VariableNames', {'Sigma_A', 'SNR_dB_vs_L633_load', 'WindowAccuracy', ...
    'WindowHIFRecall', 'WindowFalseHIF', 'RunDependability', 'RunDependabilityWeak', ...
    'RunSecurity', 'FalseTrips', 'FalseTripsAdjacent', 'FalseTripsNormalSwitching', ...
    'FalseTripsPreInception', 'Sequences'});
Tab.SNR_dB_vs_L633_load(Tab.Sigma_A == 0) = Inf;
writetable(Tab, fullfile(projectRoot, 'results', 'noise_robustness_relay.csv'));

% ---------------------------------------------------------------- figure
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1150 430]);
try
    theme(fig, 'light');
catch
end
tl = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
xs = SIGMAS;
xs(1) = 0.002;   % plot sigma = 0 at the left edge of the log axis
ax = nexttile(tl);
semilogx(ax, xs, 100 * rows(:, 3), '-o', xs, 100 * rows(:, 4), '-s', xs, 100 * rows(:, 5), '-^', 'LineWidth', 1.5);
grid(ax, 'on');
xlabel(ax, 'Measurement noise \sigma per phase (A)   [left-most point: no noise]');
ylabel(ax, '%');
title(ax, '(a) Window level (held-out test runs)');
legend(ax, {'accuracy', 'HIF recall', 'false-HIF rate'}, 'Location', 'west');
ax = nexttile(tl);
semilogx(ax, xs, 100 * rows(:, 6), '-o', xs, 100 * rows(:, 7), '-s', xs, 100 * rows(:, 8), '-^', 'LineWidth', 1.5);
grid(ax, 'on');
xlabel(ax, 'Measurement noise \sigma per phase (A)');
ylabel(ax, '%');
ylim(ax, [0 105]);
title(ax, '(b) Run level (open loop), 2-of-3 vote over consecutive windows');
legend(ax, {'dependability (HIF sequences, \geq 3 post-inception windows)', 'dependability (weak boundary arcs)', ...
    'security (sequences without a false 2-of-3 vote)'}, 'Location', 'southwest');
outDir = fullfile(projectRoot, 'results', 'report_figures');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
exportgraphics(fig, fullfile(outDir, 'fig_noise_robustness.png'), 'Resolution', 200);
close(fig);
fprintf('Saved results/noise_robustness_relay.csv and results/report_figures/fig_noise_robustness.png\n');
