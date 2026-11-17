%% profile_all_relays.m
% Journal comparison study: per-decision compute time of every relay model
% under identical conditions - one MATLAB computational thread, one window at a
% time, all models timed back to back on each of 1000 held-out test windows, so
% thermal or power changes affect them equally. Also the in-memory size of
% each classifier as the relay would hold it.
%
% Models: db4 feature extraction; RF (flattened, clean and noise-trained),
% LightGBM (flattened, clean and noise-trained), wide 1D-CNN (clean and
% noise-trained), both on hand-written MATLAB forward passes; SVM and MLP
% through predict(), including its MATLAB object overhead. Feature-based
% models add the feature-extraction time.
%
% Output: results/dl/comparative/compute_all.csv, compute_all_power.txt
% Run in a batch worker on an otherwise idle machine.

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);
outDir = fullfile(projectRoot, 'results', 'dl', 'comparative');
modDir = fullfile(projectRoot, 'models');
maxNumCompThreads(1);
[~, powerBefore] = system('powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus"');

man = jsondecode(fileread(fullfile(projectRoot, 'data', 'dl', 'manifest.json')));
W = man.window_len;
fid = fopen(fullfile(projectRoot, 'data', 'dl', 'windows_f32.bin'), 'r');
raw = reshape(fread(fid, inf, 'single=>single'), W, 3, []);
fclose(fid);
Wtab = readtable(fullfile(projectRoot, 'data', 'dl', 'windows.csv'), 'TextType', 'string');
test = find(Wtab.split == "test");
idx = test(round(linspace(1, numel(test), 1000)));

R1 = load(fullfile(modDir, 'hif_relay_model.mat'), 'relayModel', 'scaler');
R2 = load(fullfile(modDir, 'hif_relay_model_noiseaug.mat'), 'relayModel', 'scaler');
F1 = rf_flatten(R1.relayModel);
F2 = rf_flatten(R2.relayModel);
L1 = load(fullfile(modDir, 'hif_relay_lgbm.mat'), 'lgbm');
L2 = load(fullfile(modDir, 'hif_relay_lgbm_noiseaug.mat'), 'lgbm');
C1 = load(fullfile(modDir, 'hif_relay_cnn_wide.mat'), 'cnn');
C2 = load(fullfile(modDir, 'hif_relay_cnn_wide_noiseaug.mat'), 'cnn');
T = load(fullfile(modDir, 'trained_classifiers.mat'), 'mdlSVM', 'mdlNN', 'scaler');
svm = compact(T.mdlSVM);
mlp = compact(T.mdlNN);
mu = T.scaler.mu;
sd = T.scaler.sigma;

names = {'features', 'rf', 'rf_aug', 'lgbm', 'lgbm_aug', 'cnn_wide_ref', 'cnn_wide_ref_aug', 'svm', 'mlp'};
t = zeros(numel(idx), numel(names));
for r = -20:numel(idx)                    % r <= 0: warm-up, not recorded
    win = raw(:, :, idx(max(r, 1)));
    t0 = tic; f = hif_window_features(win); dt(1) = toc(t0);
    z1 = (f - R1.scaler.mu) ./ R1.scaler.sigma;
    z2 = (f - R2.scaler.mu) ./ R2.scaler.sigma;
    z3 = (f - mu) ./ sd;
    t0 = tic; rf_predict_flat(F1, z1); dt(2) = toc(t0);
    t0 = tic; rf_predict_flat(F2, z2); dt(3) = toc(t0);
    t0 = tic; lgbm_predict_flat(L1.lgbm, f); dt(4) = toc(t0);
    t0 = tic; lgbm_predict_flat(L2.lgbm, f); dt(5) = toc(t0);
    t0 = tic; cnn_predict_window(C1.cnn, win); dt(6) = toc(t0);
    t0 = tic; cnn_predict_window(C2.cnn, win); dt(7) = toc(t0);
    t0 = tic; predict(svm, z3); dt(8) = toc(t0);
    t0 = tic; predict(mlp, z3); dt(9) = toc(t0);
    if r > 0
        t(r, :) = dt;
    end
end

sizes = [0, bytesOf(F1), bytesOf(F2), bytesOf(L1.lgbm), bytesOf(L2.lgbm), bytesOf(C1.cnn), bytesOf(C2.cnn), bytesOf(svm), bytesOf(mlp)];
usesFeatures = [false, true, true, true, true, false, false, true, true];
total = t + usesFeatures .* t(:, 1);
total(:, 1) = t(:, 1);
Tab = table(string(names'), 1e3 * median(t, 1)', 1e3 * prctile(t, 99, 1)', 1e3 * median(total, 1)', 1e3 * prctile(total, 99, 1)', ...
    sizes' / 1024, usesFeatures', 'VariableNames', {'Model', 'ClassifierMedian_ms', 'ClassifierP99_ms', 'DecisionMedian_ms', ...
    'DecisionP99_ms', 'InMemory_kB', 'UsesWaveletFeatures'});
writetable(Tab, fullfile(outDir, 'compute_all.csv'));
[~, powerAfter] = system('powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus"');
fid = fopen(fullfile(outDir, 'compute_all_power.txt'), 'w');
fprintf(fid, 'before: %safter: %s', powerBefore, powerAfter);
fclose(fid);
disp(Tab);
fprintf('power before %s after %s\n', strtrim(powerBefore), strtrim(powerAfter));

%% ======================================================================
function b = bytesOf(x) %#ok<INUSD>
w = whos('x');
b = w.bytes;
end
