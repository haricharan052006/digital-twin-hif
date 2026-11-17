%% export_noise_augmented_train.m
% Journal comparison study: noise-augmented TRAINING data shared by the RF,
% LightGBM and 1D-CNN retraining.
%
% Every training window of data/dl/windows.csv (split = train, all folds)
% gets COPIES noisy copies. Each copy has its own noise level sigma, drawn
% log-uniformly from [SIGMA_MIN, SIGMA_MAX] A, and white Gaussian noise of
% that standard deviation is added to each phase of the raw residual - the
% same noise model as the test sweep (export_noisy_test.m), with a different
% random stream (rng(AUG_SEED)) and continuous sigma, so no training copy
% repeats a test level or a test noise draw. The clean windows stay in the
% training set; the models train on clean + copies. Held-out test windows
% are never touched.
%
% Outputs (data/dl/aug/):
%   windows_f32.bin   float32 C-order [nAug x 3 x W] noisy raw windows (A)
%   features_f64.bin  float64 C-order [nAug x 87] db4 features of those windows
%   windows_aug.csv   per copy: source row (windows.csv), copy index, sigma
%   aug.json          settings
%
% Requires: Wavelet Toolbox.

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);
COPIES    = 2;
SIGMA_MIN = 0.005;    % A
SIGMA_MAX = 0.1;      % A
AUG_SEED  = 3031;
outDir = fullfile(projectRoot, 'data', 'dl', 'aug');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

Wtab = readtable(fullfile(projectRoot, 'data', 'dl', 'windows.csv'), 'TextType', 'string');
man = jsondecode(fileread(fullfile(projectRoot, 'data', 'dl', 'manifest.json')));
W = man.window_len;
fid = fopen(fullfile(projectRoot, 'data', 'dl', 'windows_f32.bin'), 'r');
raw = reshape(fread(fid, inf, 'single=>single'), W, 3, []);
fclose(fid);
train = find(Wtab.split == "train");
nTr = numel(train);
nAug = COPIES * nTr;

rng(AUG_SEED, 'twister');
src = repmat(train, COPIES, 1);
copyIdx = repelem((1:COPIES)', nTr);
sigma = exp(log(SIGMA_MIN) + (log(SIGMA_MAX) - log(SIGMA_MIN)) * rand(nAug, 1));
Wn = zeros(W, 3, nAug, 'single');
Xn = zeros(nAug, 87);
tic;
for k = 1:nAug
    seg = double(raw(:, :, src(k))) + sigma(k) * randn(W, 3);
    Wn(:, :, k) = seg;
    Xn(k, :) = hif_window_features(seg);
end
fprintf('%d noisy copies of %d training windows (sigma %.3f-%.3f A, log-uniform) in %.0f s\n', ...
    nAug, nTr, SIGMA_MIN, SIGMA_MAX, toc);

writeBin(fullfile(outDir, 'windows_f32.bin'), Wn, 'single');
writeBin(fullfile(outDir, 'features_f64.bin'), Xn', 'double');
writetable(table(src, copyIdx, sigma, 'VariableNames', {'source_row', 'copy', 'sigma'}), ...
    fullfile(outDir, 'windows_aug.csv'));
info = struct('copies', COPIES, 'sigma_min', SIGMA_MIN, 'sigma_max', SIGMA_MAX, 'distribution', 'log-uniform', ...
    'seed', AUG_SEED, 'n', nAug, 'shape', [nAug 3 W], 'n_features', 87);
fid = fopen(fullfile(outDir, 'aug.json'), 'w');
fprintf(fid, '%s', jsonencode(info, 'PrettyPrint', true));
fclose(fid);
fprintf('Saved data/dl/aug/*\n');

%% ======================================================================
function writeBin(file, A, precision)
fid = fopen(file, 'w');
cleanup = onCleanup(@() fclose(fid));
n = fwrite(fid, A, precision);
assert(n == numel(A), 'Short write to %s.', file);
end
