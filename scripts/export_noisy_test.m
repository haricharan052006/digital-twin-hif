%% export_noisy_test.m
% Journal comparison study, stage 3: the measurement-noise sweep of
% benchmark_noise_robustness.m, made model-independent.
%
% For every sigma the held-out test windows get exactly the noise of
% benchmark_noise_robustness.m (same SIGMAS, rng(RNG_SEED + i), same window
% order, sigma * randn(W, 3) added to the raw residual), so the RF, LightGBM
% and the 1D-CNN are scored on identical noisy windows:
%   - raw noisy windows are written for the CNN,
%   - their 87 db4 features for LightGBM,
%   - the deployed relay RF (models/hif_relay_model.mat) is predicted here.
% Check: the RF scored through relay_window_metrics.m must reproduce
% results/noise_robustness_relay.csv at every sigma.
%
% Outputs:
%   data/dl/noise/windows_sigma{i}.bin    float32 C-order [nTest x 3 x W] (A)
%   data/dl/noise/features_sigma{i}.bin   float64 C-order [nTest x 87]
%   data/dl/noise/noise.json              sigmas, rows (data/dl/windows.csv), seeds
%   results/dl/noise/pred_rf_sigma{i}.csv deployed RF predictions
%
% Requires: Wavelet Toolbox, Statistics and Machine Learning Toolbox.

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);
SIGMAS = [0 0.005 0.01 0.02 0.05 0.1 0.2 0.5];   % A, per phase - as benchmark_noise_robustness.m
RNG_SEED = 2026;
noiseDir = fullfile(projectRoot, 'data', 'dl', 'noise');
predDir = fullfile(projectRoot, 'results', 'dl', 'noise');
for d = {noiseDir, predDir}
    if ~exist(d{1}, 'dir')
        mkdir(d{1});
    end
end

Wtab = readtable(fullfile(projectRoot, 'data', 'dl', 'windows.csv'), 'TextType', 'string');
F = load(fullfile(projectRoot, 'data', 'features.mat'), 'X', 'y');
R = load(fullfile(projectRoot, 'models', 'hif_relay_model.mat'), 'relayModel', 'scaler');
classNames = categories(F.y);
man = jsondecode(fileread(fullfile(projectRoot, 'data', 'dl', 'manifest.json')));
W = man.window_len;
test = find(Wtab.split == "test");       % ascending = benchmark_noise_robustness.m order
nT = numel(test);
fid = fopen(fullfile(projectRoot, 'data', 'dl', 'windows_f32.bin'), 'r');
raw = reshape(fread(fid, inf, 'single=>single'), W, 3, []);   % [W x 3 x N]
fclose(fid);
raw = raw(:, :, test);
ref = readtable(fullfile(projectRoot, 'results', 'noise_robustness_relay.csv'));

pCols = compose('p%d', 0:4);
for i = 1:numel(SIGMAS)
    sigma = SIGMAS(i);
    rng(RNG_SEED + i);
    Wn = zeros(W, 3, nT, 'single');
    Xn = zeros(nT, size(F.X, 2));
    for r = 1:nT
        seg = double(raw(:, :, r));
        if sigma > 0
            seg = seg + sigma * randn(W, 3);
        end
        Wn(:, :, r) = seg;
        Xn(r, :) = hif_window_features(seg);
    end
    if sigma == 0
        assert(isequal(Xn, F.X(test, :)), 'sigma = 0 does not reproduce the stored features.');
    end
    writeBin(fullfile(noiseDir, sprintf('windows_sigma%d.bin', i)), Wn, 'single');
    writeBin(fullfile(noiseDir, sprintf('features_sigma%d.bin', i)), Xn', 'double');

    [lab, score] = predict(R.relayModel, (Xn - R.scaler.mu) ./ R.scaler.sigma);
    [~, c] = ismember(lab, classNames);
    writetable([table(Wtab.row(test), c - 1, 'VariableNames', {'row', 'pred'}), ...
        array2table(score, 'VariableNames', pCols)], fullfile(predDir, sprintf('pred_rf_sigma%d.csv', i)));

    m = relay_window_metrics(Wtab(test, :), c - 1);
    e = ref(i, :);
    got = [m.Accuracy, m.HifRecall, m.FalseHifRate, m.Dependability, m.DependabilityWeak, m.Security, m.FalseTrips];
    want = [e.WindowAccuracy, e.WindowHIFRecall, e.WindowFalseHIF, e.RunDependability, e.RunDependabilityWeak, ...
        e.RunSecurity, e.FalseTrips];
    fprintf('sigma %.3f A: RF acc %.4f, HIF recall %.4f, dependability %.4f, false trips %d | max |diff| vs stored benchmark %g\n', ...
        sigma, m.Accuracy, m.HifRecall, m.Dependability, m.FalseTrips, max(abs(got - want)));
    assert(abs(e.Sigma_A - sigma) < 1e-12 && max(abs(got - want)) < 1e-12, ...
        'RF on the regenerated noisy windows does not reproduce results/noise_robustness_relay.csv.');
end

info.sigmas = SIGMAS;
info.rng_seed = RNG_SEED;
info.rows = Wtab.row(test);
info.shape = [nT 3 W];
info.n_features = size(F.X, 2);
fid = fopen(fullfile(noiseDir, 'noise.json'), 'w');
fprintf(fid, '%s', jsonencode(info));
fclose(fid);
fprintf('Saved data/dl/noise/* and results/dl/noise/pred_rf_sigma*.csv\n');

%% ======================================================================
function writeBin(file, A, precision)
fid = fopen(file, 'w');
cleanup = onCleanup(@() fclose(fid));
n = fwrite(fid, A, precision);
assert(n == numel(A), 'Short write to %s.', file);
end
