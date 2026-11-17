%% rf_cv_shared_folds.m
% Journal comparison study, stage 1: Random Forest baseline on the SHARED
% run-grouped folds of data/dl/windows.csv (export_dl_dataset.m), so its
% cross-validation numbers are directly comparable with LightGBM and the
% 1D-CNN, which are cross-validated on the same folds.
%
%   cross-validation  for each fold k: z-score scaler fit on the training
%                     windows of the other folds only, the relay's Random
%                     Forest recipe (train_classifiers.m: bagged, 100 trees,
%                     Reproducible template, rng 42), predict fold k.
%   held-out test     the DEPLOYED relay bundle models/hif_relay_model.mat
%                     (not retrained) on the 180 test runs - the reference
%                     the other models are compared against. Must
%                     reproduce train_classifiers.m's stored test accuracy
%                     and the clean row of results/noise_robustness_relay.csv.
%
% All metrics come from relay_window_metrics.m.
%
% Outputs (results/dl/):
%   pred_rf_cv.csv          out-of-fold predictions: row, fold, pred, p0..p4
%   pred_rf_test.csv        deployed relay on the test windows: row, pred, p0..p4
%   rf_cv_shared_folds.csv  metrics per fold, pooled out-of-fold, and test
%
% Requires: Statistics and Machine Learning Toolbox, Wavelet Toolbox (no -
% features come precomputed from data/features.mat).

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);
outDir = fullfile(projectRoot, 'results', 'dl');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

F = load(fullfile(projectRoot, 'data', 'features.mat'), 'X', 'y');
W = readtable(fullfile(projectRoot, 'data', 'dl', 'windows.csv'), 'TextType', 'string');
assert(height(W) == size(F.X, 1) && isequal(W.code, double(F.y) - 1), ...
    'data/dl/windows.csv does not match data/features.mat - rerun export_dl_dataset.m.');
X = F.X;
classNames = categories(F.y);
nFolds = max(W.fold);

tTree = templateTree('Reproducible', true);
trainRF = @(Xt, yt) fitcensemble(Xt, yt, 'Method', 'Bag', 'NumLearningCycles', 100, ...
    'Learners', tTree, 'ClassNames', classNames);

%% ------------------------------------------------------ cross-validation
N = height(W);
oofPred = nan(N, 1);
oofScore = nan(N, 5);
rows = {};
for k = 1:nFolds
    tr = W.split == "train" & W.fold ~= k;
    va = W.fold == k;
    mu = mean(X(tr, :), 1);
    sd = std(X(tr, :), 0, 1);
    sd(sd == 0) = 1;
    rng(42);
    tic;
    mdl = trainRF((X(tr, :) - mu) ./ sd, F.y(tr));
    tFit = toc;
    [lab, score] = predict(mdl, (X(va, :) - mu) ./ sd);
    [~, c] = ismember(lab, classNames);
    oofPred(va) = c - 1;
    oofScore(va, :) = score;
    m = relay_window_metrics(W(va, :), oofPred(va));
    rows(end + 1, :) = metricRow(sprintf('fold %d', k), nnz(tr), nnz(va), m); %#ok<SAGROW>
    fprintf('fold %d: fit %.0f s on %d windows | acc %.4f, HIF recall %.4f, false-HIF %.4f, dependability %.3f (weak %.3f), false trips %d\n', ...
        k, tFit, nnz(tr), m.Accuracy, m.HifRecall, m.FalseHifRate, m.Dependability, m.DependabilityWeak, m.FalseTrips);
end
cvRows = W.split == "train";
assert(~any(isnan(oofPred(cvRows))), 'Some training windows got no out-of-fold prediction.');
mCV = relay_window_metrics(W(cvRows, :), oofPred(cvRows));
rows(end + 1, :) = metricRow('CV pooled', NaN, nnz(cvRows), mCV);

%% ---------------------------------------- deployed relay on the test runs
R = load(fullfile(projectRoot, 'models', 'hif_relay_model.mat'), 'relayModel', 'scaler');
te = W.split == "test";
[lab, score] = predict(R.relayModel, (X(te, :) - R.scaler.mu) ./ R.scaler.sigma);
[~, c] = ismember(lab, classNames);
testPred = c - 1;
mTest = relay_window_metrics(W(te, :), testPred);
rows(end + 1, :) = metricRow('test (deployed relay)', NaN, nnz(te), mTest);

% consistency with the stored baseline numbers
T = load(fullfile(projectRoot, 'models', 'trained_classifiers.mat'), 'results');
noise = readtable(fullfile(projectRoot, 'results', 'noise_robustness_relay.csv'));
clean = noise(noise.Sigma_A == 0, :);
fprintf('\nDeployed relay on test runs: acc %.4f (stored %.4f), dependability %.4f (stored %.4f), weak %.4f (stored %.4f), false trips %d (stored %d)\n', ...
    mTest.Accuracy, T.results.RandomForest.Accuracy, mTest.Dependability, clean.RunDependability, ...
    mTest.DependabilityWeak, clean.RunDependabilityWeak, mTest.FalseTrips, clean.FalseTrips);
assert(abs(mTest.Accuracy - T.results.RandomForest.Accuracy) < 1e-12 && ...
    abs(mTest.Dependability - clean.RunDependability) < 1e-12 && ...
    abs(mTest.DependabilityWeak - clean.RunDependabilityWeak) < 1e-12 && ...
    mTest.FalseTrips == clean.FalseTrips, ...
    'relay_window_metrics does not reproduce the stored baseline numbers.');

%% ------------------------------------------------------------------ save
pCols = compose('p%d', 0:4);
writetable([table(W.row(cvRows), W.fold(cvRows), oofPred(cvRows), 'VariableNames', {'row', 'fold', 'pred'}), ...
    array2table(oofScore(cvRows, :), 'VariableNames', pCols)], fullfile(outDir, 'pred_rf_cv.csv'));
writetable([table(W.row(te), testPred, 'VariableNames', {'row', 'pred'}), ...
    array2table(score, 'VariableNames', pCols)], fullfile(outDir, 'pred_rf_test.csv'));
Tab = cell2table(rows, 'VariableNames', {'Set', 'TrainWindows', 'EvalWindows', 'Accuracy', 'MacroF1', ...
    'HifRecall', 'HifRecallWeak', 'FalseHifRate', 'Dependability', 'DependabilityWeak', 'Security', ...
    'FalseTrips', 'FalseTripsAdjacent', 'FalseTripsNormalSwitching', 'FalseTripsPreInception', 'Sequences'});
writetable(Tab, fullfile(outDir, 'rf_cv_shared_folds.csv'));
disp(Tab);
fprintf('Saved results/dl/{pred_rf_cv.csv, pred_rf_test.csv, rf_cv_shared_folds.csv}\n');

%% ======================================================================
function r = metricRow(name, nTrain, nEval, m)
r = {name, nTrain, nEval, m.Accuracy, m.MacroF1, m.HifRecall, m.HifRecallWeak, m.FalseHifRate, ...
    m.Dependability, m.DependabilityWeak, m.Security, m.FalseTrips, m.FalseTripsAdjacent, ...
    m.FalseTripsNormalSwitching, m.FalseTripsPreInception, m.Sequences};
end
