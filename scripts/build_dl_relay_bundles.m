function build_dl_relay_bundles(lgbmName, cnnName, suffix)
%BUILD_DL_RELAY_BUNDLES  Journal comparison study, stage 4: relay bundles for
% HIFRelayBlock.m from the LightGBM and 1D-CNN models exported by
% dl/export_relay_bundles.py, so both run inside ieee13_hif_twin_system.slx
% next to the deployed RF (run_twin_isolation_case(..., 'ModelFile', <bundle>)).
%
%   build_dl_relay_bundles()                                  clean-trained models
%   build_dl_relay_bundles('lgbm_aug', 'cnn_wide_ref_aug', '_noiseaug')
%       noise-augmented models -> hif_relay_lgbm_noiseaug.mat,
%       hif_relay_cnn_wide_noiseaug.mat
%
%   models/hif_relay_lgbm.mat      kind 'lgbm': flattened trees (lgbm_predict_flat.m)
%                                  on the raw 87 db4 features
%   models/hif_relay_cnn_wide.mat  kind 'cnn': wide 1D-CNN weights (cnn_predict_window.m)
%                                  on the raw residual window
% Both carry classNames, windowLen, hopLen and Ts like models/hif_relay_model.mat.
%
% Parity check: on every held-out test window the MATLAB predictors must
% return the labels of the Python models (results/dl/pred_<model>_test_seed<s>.csv);
% the largest class-probability difference is reported. Also reports the
% single-thread MATLAB time per decision, like-for-like with the RF relay.
%
% Requires: Wavelet Toolbox (features), Statistics and Machine Learning Toolbox.

if nargin < 3
    lgbmName = 'lgbm';
    cnnName = 'cnn_wide_ref';
    suffix = '';
end
scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);
modDir = fullfile(projectRoot, 'models');
R = load(fullfile(modDir, 'hif_relay_model.mat'), 'classNames', 'featureNames', 'windowLen', 'hopLen', 'Ts');
classNames = string(R.classNames);

%% ---------------------------------------------------------------- LightGBM
J = jsondecode(fileread(fullfile(modDir, 'dl', ['relay_export_' lgbmName '.json'])));
G.numClass = J.num_class;
G.classNames = classNames(:);
G.feature = J.feature(:) + 1;
G.threshold = J.threshold(:);
G.left = J.left(:) + 1;              % >= 1 internal node, <= 0 leaf (1 - child)
G.right = J.right(:) + 1;
G.root = J.root(:) + 1;
G.leafValue = J.leaf_value(:);
G.leafClass = J.leaf_class(:) + 1;
lgbmSeed = J.seed;
bundle = struct('kind', 'lgbm', 'lgbm', G, 'classNames', classNames, 'featureNames', {R.featureNames}, ...
    'windowLen', R.windowLen, 'hopLen', R.hopLen, 'Ts', R.Ts, 'source', ['models/dl/' J.model_file]);
save(fullfile(modDir, ['hif_relay_lgbm' suffix '.mat']), '-struct', 'bundle');

%% --------------------------------------------------------------------- CNN
J = jsondecode(fileread(fullfile(modDir, 'dl', ['relay_export_' cnnName '.json'])));
blocks = struct('weight', {}, 'stride', {}, 'dilation', {}, 'padding', {}, 'gamma', {}, 'beta', {}, ...
    'mean', {}, 'var', {}, 'eps', {});
for b = 1:numel(J.blocks)
    s = J.blocks(b);
    blocks(b).weight = permute(reshape(s.weight, fliplr(s.shape(:)')), [3 2 1]);   % C-order [Cout Cin K]
    blocks(b).stride = s.stride;
    blocks(b).dilation = s.dilation;
    blocks(b).padding = s.padding;
    blocks(b).gamma = s.gamma(:);
    blocks(b).beta = s.beta(:);
    blocks(b).mean = s.mean(:);
    blocks(b).var = s.var(:);
    blocks(b).eps = s.eps;
end
C.arch = J.arch;
C.receptiveField = J.receptive_field;
C.scaling = struct('kind', J.scaling.kind, 'ref', J.scaling.ref, 'x0', J.scaling.x0);
C.blocks = blocks;
C.headWeight = reshape(J.head_weight, fliplr(J.head_shape(:)'))';   % [5 x 128]
C.headBias = J.head_bias(:);
C.classNames = classNames(:);
cnnSeed = J.seed;
bundle = struct('kind', 'cnn', 'cnn', C, 'classNames', classNames, 'windowLen', R.windowLen, ...
    'hopLen', R.hopLen, 'Ts', R.Ts, 'source', ['models/dl/' J.model_file]);
save(fullfile(modDir, ['hif_relay_cnn_wide' suffix '.mat']), '-struct', 'bundle');

%% ------------------------------------------------------- parity on test windows
Wtab = readtable(fullfile(projectRoot, 'data', 'dl', 'windows.csv'), 'TextType', 'string');
F = load(fullfile(projectRoot, 'data', 'features.mat'), 'X');
test = find(Wtab.split == "test");
fid = fopen(fullfile(projectRoot, 'data', 'dl', 'windows_f32.bin'), 'r');
raw = reshape(fread(fid, inf, 'single=>single'), R.windowLen, 3, []);
fclose(fid);
pCols = {'p0', 'p1', 'p2', 'p3', 'p4'};
resDir = fullfile(projectRoot, 'results', 'dl');

P = readtable(fullfile(resDir, sprintf('pred_%s_test_seed%d.csv', lgbmName, lgbmSeed)));
[lab, prob] = lgbm_predict_flat(G, F.X(test, :));
[~, code] = ismember(lab, classNames);
fprintf('LightGBM seed %d: %d / %d test labels differ from Python, max |dp| = %.3g\n', lgbmSeed, ...
    nnz(code - 1 ~= P.pred), numel(test), max(abs(prob - P{:, pCols}), [], 'all'));
assert(isequal(code - 1, P.pred), 'MATLAB LightGBM labels differ from Python.');

P = readtable(fullfile(resDir, sprintf('pred_%s_test_seed%d.csv', cnnName, cnnSeed)));
prob = zeros(numel(test), 5);
for r = 1:numel(test)
    [~, prob(r, :)] = cnn_predict_window(C, raw(:, :, test(r)));
end
[~, code] = max(prob, [], 2);
nDiff = nnz(code - 1 ~= P.pred);
fprintf('CNN wide seed %d: %d / %d test labels differ from Python, max |dp| = %.3g\n', cnnSeed, ...
    nDiff, numel(test), max(abs(prob - P{:, pCols}), [], 'all'));
assert(nDiff == 0, 'MATLAB CNN labels differ from Python.');

%% ------------------------------------------- single-thread MATLAB decision time
prev = maxNumCompThreads(1);
nT = numel(test);
tL = zeros(nT, 1);
tC = zeros(nT, 1);
for r = 1:nT
    win = raw(:, :, test(r));
    t0 = tic;
    lgbm_predict_flat(G, hif_window_features(win));
    tL(r) = toc(t0);
    t0 = tic;
    cnn_predict_window(C, win);
    tC(r) = toc(t0);
end
maxNumCompThreads(prev);
fprintf('MATLAB, 1 thread, per decision: LightGBM incl. db4 features median %.3f ms (p99 %.3f), CNN wide median %.3f ms (p99 %.3f)\n', ...
    1e3 * median(tL), 1e3 * prctile(tL, 99), 1e3 * median(tC), 1e3 * prctile(tC, 99));
timing = struct('lgbm_with_features_median_ms', 1e3 * median(tL), 'lgbm_with_features_p99_ms', 1e3 * prctile(tL, 99), ...
    'cnn_wide_median_ms', 1e3 * median(tC), 'cnn_wide_p99_ms', 1e3 * prctile(tC, 99), 'n', nT, ...
    'lgbm_seed', lgbmSeed, 'cnn_seed', cnnSeed);
fid = fopen(fullfile(resDir, ['compute_matlab_dl_relays' suffix '.json']), 'w');
fprintf(fid, '%s', jsonencode(timing, 'PrettyPrint', true));
fclose(fid);
fprintf('Saved models/hif_relay_lgbm%s.mat, models/hif_relay_cnn_wide%s.mat, results/dl/compute_matlab_dl_relays%s.json\n', ...
    suffix, suffix, suffix);
end
