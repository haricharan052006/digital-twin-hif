%% export_dl_dataset.m
% Journal comparison study, stage 1: exports the relay windows of
% data/features.mat in a language-neutral form for the Python models
% (end-to-end 1D-CNN on the raw residual windows, LightGBM on the 87 db4
% features) and fixes ONE run-grouped fold assignment that every model -
% Random Forest, LightGBM and CNN - is cross-validated on.
%
% Windows are NOT re-labelled or re-cut on a new grid: every row is exactly
% a row of data/features.mat (same run, lateral, start time, label), so the
% CNN sees the raw samples the RF features were computed from. This is
% checked by recomputing hif_window_features on every exported window and
% requiring a bit-identical match with the stored X.
%
% Split:
%   test  - the 180 held-out runs of train_classifiers.m
%           (models/trained_classifiers.mat results.testRuns), unchanged, so
%           the deployed relay RF is evaluated on the same runs as the rest.
%   train - the other 720 runs, divided into FOLDS run-grouped folds,
%           stratified by run event class x dataset source (main | boundary),
%           so weak boundary arcs are spread evenly over the folds.
%
% Outputs (data/dl/):
%   windows_f32.bin   float32, C-order [N x 3 x WINDOW_LEN] raw residual (A),
%                     phases A/B/C, oldest sample first
%   features_f64.bin  float64, C-order [N x 87] = features.mat X
%   windows.csv       one row per window: row, run, source, lateral, tStart,
%                     label, code (0 Normal, 1 Switching_Transient, 2/3/4 HIF
%                     phase A/B/C - the HIFRelayBlock class codes), split,
%                     fold (0 = test), faulted (window's lateral is the faulted
%                     lateral of an HIF run), adjacent (other lateral of an HIF
%                     run), weak (faulted and from the boundary dataset)
%   runs.csv          one row per run: metadata, event kind, split, fold
%   manifest.json     shapes, dtypes, class / feature names, seeds
%
% Requires: Wavelet Toolbox, Statistics and Machine Learning Toolbox.

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);
dataDir = fullfile(projectRoot, 'data');
outDir  = fullfile(dataDir, 'dl');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
FOLDS     = 5;
FOLD_SEED = 2027;

%% ------------------------------------------------------------ inputs
F = load(fullfile(dataDir, 'features.mat'), 'X', 'y', 'runIdx', 'runSource', 'lateral', ...
    'tStart', 'featureNames', 'WINDOW_LEN', 'HOP_LEN', 'Ts');
T = load(fullfile(projectRoot, 'models', 'trained_classifiers.mat'), 'results');
S = load(fullfile(dataDir, 'raw_residuals.mat'), 'dI633L', 'dI675L', 'tGrid', 'meta');
B = load(fullfile(dataDir, 'raw_residuals_boundary.mat'), 'dI633L', 'dI675L', 'tGrid', 'meta');
assert(isequal(S.tGrid, B.tGrid), 'Boundary dataset uses a different time grid.');
res = {cat(3, S.dI633L, B.dI633L), cat(3, S.dI675L, B.dI675L)};
meta = [S.meta(:); B.meta(:)];
tGrid = S.tGrid;
clear S B

W = F.WINDOW_LEN;
N = numel(F.y);
classNames = string(categories(F.y))';
code = double(F.y) - 1;
runs = (1:numel(meta))';
nRuns = numel(runs);
fprintf('features.mat: %d windows, %d runs, window %d samples\n', N, nRuns, W);

%% ------------------------------------------------- run table + folds
src = repmat("main", nRuns, 1);
src(unique(F.runIdx(F.runSource == 'boundary'))) = "boundary";
kind = strings(nRuns, 1);
for k = 1:nRuns
    switch meta(k).type
        case 'HIF'
            kind(k) = "HIF_Phase_" + meta(k).phase;
        otherwise
            kind(k) = string(meta(k).type);
    end
end
isTest = ismember(runs, T.results.testRuns);
fold = zeros(nRuns, 1);
trainRuns = runs(~isTest);
rng(FOLD_SEED, 'twister');
cv = cvpartition(categorical(kind(trainRuns) + "/" + src(trainRuns)), 'KFold', FOLDS, 'Stratify', true);
for k = 1:FOLDS
    fold(trainRuns(test(cv, k))) = k;
end
split = repmat("train", nRuns, 1);
split(isTest) = "test";

runTab = table(runs, src, kind, string({meta.type})', string({meta.bus})', string({meta.phase})', ...
    string({meta.subtype})', [meta.Vp]', [meta.Vn]', [meta.Rp]', [meta.Rn]', ...
    [meta.inceptionAngleDeg]', [meta.tIncept]', [meta.switchTime]', split, fold, ...
    'VariableNames', {'run', 'source', 'kind', 'type', 'bus', 'phase', 'subtype', 'Vp', 'Vn', ...
    'Rp', 'Rn', 'inceptionAngleDeg', 'tIncept', 'switchTime', 'split', 'fold'});

fprintf('Runs: %d test, %d train in %d folds\n', nnz(isTest), numel(trainRuns), FOLDS);
for k = 1:FOLDS
    inK = fold == k;
    fprintf('  fold %d: %3d runs (HIF %d, of which boundary %d; switching %d; normal %d)\n', k, ...
        nnz(inK), nnz(inK & startsWith(kind, "HIF")), nnz(inK & src == "boundary"), ...
        nnz(inK & kind == "Switching_Transient"), nnz(inK & kind == "Normal"));
end

%% ---------------------------------------------- window table + raw windows
lat = string(F.lateral);
latIdx = double(F.lateral == '675') + 1;
[found, s0] = ismember(F.tStart, tGrid);
assert(all(found), 'Window start times are not on the residual time grid.');

isHifRun = runTab.type(F.runIdx) == "HIF";
faulted = isHifRun & runTab.bus(F.runIdx) == lat;
adjacent = isHifRun & ~faulted;
weak = faulted & runTab.source(F.runIdx) == "boundary";

Wn = zeros(W, 3, N, 'single');   % column-major [W x 3 x N] = C-order [N x 3 x W]
dev = 0;
tic;
for r = 1:N
    seg = res{latIdx(r)}(s0(r):s0(r) + W - 1, :, F.runIdx(r));
    Wn(:, :, r) = seg;
    dev = max(dev, max(abs(hif_window_features(seg) - F.X(r, :))));
end
fprintf('Recomputed features of all %d windows in %.0f s: max |diff| vs features.mat = %g\n', N, toc, dev);
assert(dev == 0, 'Exported windows do not reproduce features.mat bit for bit.');

winTab = table((1:N)', F.runIdx, string(F.runSource), lat, F.tStart, string(F.y), code, ...
    split(F.runIdx), fold(F.runIdx), faulted, adjacent, weak, ...
    'VariableNames', {'row', 'run', 'source', 'lateral', 'tStart', 'label', 'code', 'split', ...
    'fold', 'faulted', 'adjacent', 'weak'});

%% ------------------------------------------------------------------ write
writeBin(fullfile(outDir, 'windows_f32.bin'), Wn, 'single');
writeBin(fullfile(outDir, 'features_f64.bin'), F.X', 'double');
writetable(winTab, fullfile(outDir, 'windows.csv'));
writetable(runTab, fullfile(outDir, 'runs.csv'));

man.description = 'HIF relay windows exported by scripts/export_dl_dataset.m';
man.n_windows = N;
man.window_len = W;
man.hop_len = F.HOP_LEN;
man.fs_hz = 1 / F.Ts;
man.windows = struct('file', 'windows_f32.bin', 'dtype', 'float32', 'order', 'C', ...
    'shape', [N 3 W], 'units', 'A');
man.features = struct('file', 'features_f64.bin', 'dtype', 'float64', 'order', 'C', ...
    'shape', [N numel(F.featureNames)]);
man.class_names = classNames;
man.feature_names = string(F.featureNames);
man.folds = FOLDS;
man.fold_seed = FOLD_SEED;
man.test_runs_source = 'models/trained_classifiers.mat results.testRuns';
man.created = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
fid = fopen(fullfile(outDir, 'manifest.json'), 'w');
fprintf(fid, '%s', jsonencode(man, 'PrettyPrint', true));
fclose(fid);

fprintf('Windows per split: train %d, test %d\n', nnz(winTab.split == "train"), nnz(winTab.split == "test"));
fprintf('Saved data/dl/{windows_f32.bin, features_f64.bin, windows.csv, runs.csv, manifest.json}\n');

%% ======================================================================
function writeBin(file, A, precision)
fid = fopen(file, 'w');
cleanup = onCleanup(@() fclose(fid));
n = fwrite(fid, A, precision);
assert(n == numel(A), 'Short write to %s.', file);
end
