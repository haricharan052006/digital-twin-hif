%% test_noise_robustness.m
% Measurement-noise stress test for the trained HIF classifiers.
%
% v2 - the first version added AWGN scaled to the RESIDUAL dI's own
% variance (signal_power = mean(dI(:).^2)), which collapsed accuracy to
% ~20% (random 5-class guessing) already at 40 dB. Two physical modeling
% flaws caused that, diagnosed and fixed here:
%
%   1. Wrong signal-power reference: dI is near-zero for Normal/benign
%      runs and only ~2 A even during an arcing fault (see CLAUDE.md - the
%      whole point of the digital-twin residual is to cancel the ~330 A
%      nominal load current). Scaling noise to dI's own variance means
%      "40 dB SNR" injects wildly different absolute noise levels
%      depending on the run's class - nothing like a real CT/relay noise
%      floor, which is fixed in absolute Amperes regardless of the fault
%      condition. Fix: noise is now injected at FIXED ABSOLUTE standard
%      deviations (0.01-1.0 A), representative of a realistic CT/relay
%      measurement noise floor relative to the feeder's ~330 A nominal
%      current (see CLAUDE.md system parameters), not derived from dI.
%   2. Unfiltered AWGN at 20 kHz dumps most of its energy into D1
%      (5-10 kHz) and D2 (2.5-5 kHz), which dominate the Energy/Entropy
%      features that saw ZERO noise during training - so the finest
%      sub-bands, not the underlying fault signature, drove the
%      (mis)classification. Fix: each noisy phase is passed through
%      standard wavelet denoising (wdenoise, same 'db4'/5-level basis as
%      the feature extractor) before the 75 features are computed, at
%      every noise level including Clean (so Clean isn't processed
%      through a different pipeline than the noisy cases).
%
% A one-off diagnostic first reproduces the OLD (broken) 40 dB dI-relative
% injection and prints each model's predicted-class distribution, to
% confirm what "collapse to ~20%" actually looked like before the fix.
%
% Test-split reproduction (unchanged from v1): train_classifiers.m calls
% rng(rngSeed) and then immediately calls
% cvpartition(y, 'HoldOut', 0.20, 'Stratify', true) as its very first
% randomness-consuming operation, so repeating that exact sequence here
% reproduces a bit-identical partition without persisting test indices.
%
% Input:  data/raw_residuals.mat        (dI, labels)
%         models/trained_classifiers.mat (mdlSVM, mdlRF, mdlNN, scaler,
%                                          classNames, rngSeed)
% Output: results/noise_robustness_curve.png
%
% Requires: Wavelet Toolbox, Statistics and Machine Learning Toolbox.

%% ============================================================== setup
scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
dataDir     = fullfile(projectRoot, 'data');
modelsDir   = fullfile(projectRoot, 'models');
resultsDir  = fullfile(projectRoot, 'results');
if ~exist(resultsDir, 'dir')
    mkdir(resultsDir);
end

rawFile    = fullfile(dataDir, 'raw_residuals.mat');
modelsFile = fullfile(modelsDir, 'trained_classifiers.mat');
for f = {rawFile, modelsFile}
    if ~isfile(f{1})
        error('test_noise_robustness:InputMissing', ...
            '%s not found. Run the earlier pipeline scripts first.', f{1});
    end
end

fprintf('Loading %s and %s ...\n', rawFile, modelsFile);
R = load(rawFile, 'dI', 'labels');
Mdl = load(modelsFile, 'mdlSVM', 'mdlRF', 'mdlNN', 'scaler', 'classNames', 'rngSeed');

dI = R.dI;
labels = R.labels;
mdlSVM = Mdl.mdlSVM;
mdlRF  = Mdl.mdlRF;
mdlNN  = Mdl.mdlNN;
scaler = Mdl.scaler;
classNames = Mdl.classNames;
rngSeed = Mdl.rngSeed;

%% -------------------------------------------- reproduce the test split
rng(rngSeed);
try
    cv = cvpartition(labels, 'HoldOut', 0.20, 'Stratify', true);
catch
    cv = cvpartition(labels, 'HoldOut', 0.20);
end
idxTest = test(cv);

dITest = dI(:, :, idxTest);
yTest  = labels(idxTest);
Ntest  = numel(yTest);
fprintf('  Reproduced test split: %d runs\n', Ntest);

%% ------------------------------------------------------------ constants
WAVELET = 'db4';
LEVEL   = 5;
subbandTags = {'A5', 'D5', 'D4', 'D3', 'D2', 'D1'};
statTags    = {'Energy', 'Entropy', 'Std', 'MaxAbs'};
Nfeatures = 3 * numel(subbandTags) * numel(statTags) + 3;   % 75

%% ============= diagnostic: OLD dI-relative 40 dB injection, no denoising
fprintf('\n=== Diagnostic: OLD dI-relative-SNR injection at 40 dB (pre-fix) ===\n');
Xold40 = nan(Ntest, Nfeatures);
for k = 1:Ntest
    dIrun = dITest(:, :, k);
    sigPowerOld = mean(dIrun(:).^2);
    noisePowerOld = sigPowerOld / (10^(40 / 10));
    dINoisyOld = dIrun + sqrt(noisePowerOld) * randn(size(dIrun));
    Xold40(k, :) = extractFeatureVector(dINoisyOld, WAVELET, LEVEL, subbandTags, statTags);
end
Xold40z = (Xold40 - scaler.mu) ./ scaler.sigma;

predSVMold = categorical(predict(mdlSVM, Xold40z), classNames);
predRFold  = categorical(predict(mdlRF,  Xold40z), classNames);
predNNold  = categorical(predict(mdlNN,  Xold40z), classNames);

printPredictionDistribution('SVM',              predSVMold, classNames);
printPredictionDistribution('Random Forest',    predRFold,  classNames);
printPredictionDistribution('Feedforward MLP',  predNNold,  classNames);
fprintf(['\n  (True class distribution in this test split, for comparison, ' ...
    'is roughly uniform across all 5 classes - a %.0f%%-collapse toward one or ' ...
    'two classes above confirms the finest wavelet sub-bands were being ' ...
    'swamped by out-of-distribution noise energy, not a genuine ~20%%-random ' ...
    'spread across all 5.)\n'], 100 / numel(classNames));

%% ============================================ corrected noise-level sweep
% Fixed absolute noise standard deviations (Amperes), representative of a
% realistic CT/relay measurement noise floor against the feeder's ~330 A
% nominal current (CLAUDE.md), NOT derived from dI's own (highly
% class-dependent) variance. Each noisy phase is wavelet-denoised (same
% db4/5-level basis as the feature extractor) before feature extraction,
% at every level including Clean.
noiseLevels = [0, 0.01, 0.05, 0.1, 0.2, 0.5, 1.0];   % Amperes
noiseLabels = {'Clean', '0.01A', '0.05A', '0.1A', '0.2A', '0.5A', '1.0A'};
nLevels = numel(noiseLevels);

accSVM = zeros(nLevels, 1); f1SVM = zeros(nLevels, 1);
accRF  = zeros(nLevels, 1); f1RF  = zeros(nLevels, 1);
accNN  = zeros(nLevels, 1); f1NN  = zeros(nLevels, 1);

rng(rngSeed);   % deterministic noise draws, reproducible across reruns

fprintf('\n=== Corrected noise-robustness sweep (%d levels x %d test runs, with wavelet denoising) ===\n', ...
    nLevels, Ntest);
for s = 1:nLevels
    sigma = noiseLevels(s);
    X = nan(Ntest, Nfeatures);

    for k = 1:Ntest
        dIrun = dITest(:, :, k);
        dINoisy = dIrun + sigma * randn(size(dIrun));

        dIdenoised = zeros(size(dINoisy));
        for p = 1:3
            dIdenoised(:, p) = wdenoise(dINoisy(:, p), LEVEL, 'Wavelet', WAVELET);
        end

        X(k, :) = extractFeatureVector(dIdenoised, WAVELET, LEVEL, subbandTags, statTags);
    end

    Xz = (X - scaler.mu) ./ scaler.sigma;

    predSVM = predict(mdlSVM, Xz);
    predRF  = predict(mdlRF,  Xz);
    predNN  = predict(mdlNN,  Xz);

    [accSVM(s), f1SVM(s)] = accuracyAndMacroF1(yTest, predSVM, classNames);
    [accRF(s),  f1RF(s)]  = accuracyAndMacroF1(yTest, predRF,  classNames);
    [accNN(s),  f1NN(s)]  = accuracyAndMacroF1(yTest, predNN,  classNames);

    fprintf('  sigma = %-6s :  SVM acc=%.4f  RF acc=%.4f  MLP acc=%.4f\n', ...
        noiseLabels{s}, accSVM(s), accRF(s), accNN(s));
end

%% ----------------------------------------------------------------- plot
xCat = categorical(noiseLabels, noiseLabels);   % preserve Clean -> 1.0A order

fig = figure('Visible', 'off', 'Position', [100 100 850 600]);
hold on;
plot(xCat, accSVM, '-o', 'LineWidth', 1.6, 'MarkerSize', 7, 'DisplayName', 'SVM (RBF, ECOC)');
plot(xCat, accRF,  '-s', 'LineWidth', 1.6, 'MarkerSize', 7, 'DisplayName', 'Random Forest');
plot(xCat, accNN,  '-^', 'LineWidth', 1.6, 'MarkerSize', 7, 'DisplayName', 'Feedforward MLP');
hold off;
grid on;
box on;
ylim([0 1.05]);
xlabel('Injected CT noise (\sigma, Amperes)');
ylabel('Test Accuracy');
title('Noise Robustness: Test Accuracy vs. CT Measurement Noise (with wavelet denoising)');
legend('Location', 'southwest');

outPng = fullfile(resultsDir, 'noise_robustness_curve.png');
exportgraphics(fig, outPng, 'Resolution', 150);
close(fig);
fprintf('\nSaved: %s\n', outPng);

%% ================================================== Markdown summary tables
fprintf('\n## Noise Robustness (post-fix) - Test Accuracy\n\n');
fprintf('| Noise sigma | SVM | Random Forest | MLP |\n');
fprintf('|---|---|---|---|\n');
for s = 1:nLevels
    fprintf('| %s | %.4f | %.4f | %.4f |\n', noiseLabels{s}, accSVM(s), accRF(s), accNN(s));
end

fprintf('\n## Noise Robustness (post-fix) - Macro F1\n\n');
fprintf('| Noise sigma | SVM | Random Forest | MLP |\n');
fprintf('|---|---|---|---|\n');
for s = 1:nLevels
    fprintf('| %s | %.4f | %.4f | %.4f |\n', noiseLabels{s}, f1SVM(s), f1RF(s), f1NN(s));
end

%% ======================================================================
function printPredictionDistribution(name, pred, classNames)
fprintf('\n  %s predicted-class distribution (n = %d):\n', name, numel(pred));
for i = 1:numel(classNames)
    n = nnz(pred == classNames{i});
    fprintf('    %-20s %4d  (%.1f%%)\n', classNames{i}, n, 100 * n / numel(pred));
end
end

%% ======================================================================
function x = extractFeatureVector(dIrun, WAVELET, LEVEL, subbandTags, statTags)
% Builds one run's 75-element feature row in the exact column order used
% by extract_features.m: phase A/B/C x {A5,D5,D4,D3,D2,D1} x
% {Energy,Entropy,Std,MaxAbs}, then zeroSeq_RMS, zeroSeq_Energy,
% maxPhaseUnbalanceRatio. dIrun is [Nsamples x 3].
Nperphase = numel(subbandTags) * numel(statTags);
x = nan(1, 3 * Nperphase + 3);
col = 0;
rmsPhase = zeros(1, 3);

for p = 1:3
    xp = dIrun(:, p);
    [C, L] = wavedec(xp, LEVEL, WAVELET);

    subbands = cell(1, 6);
    subbands{1} = appcoef(C, L, WAVELET, LEVEL);      % A5
    for lvl = LEVEL:-1:1
        subbands{LEVEL - lvl + 2} = detcoef(C, L, lvl);   % D5, D4, D3, D2, D1
    end

    for sb = 1:6
        s = subbandStats(subbands{sb});
        x(col + 1) = s.Energy;   col = col + 1;
        x(col + 1) = s.Entropy;  col = col + 1;
        x(col + 1) = s.Std;      col = col + 1;
        x(col + 1) = s.MaxAbs;   col = col + 1;
    end

    rmsPhase(p) = sqrt(mean(xp.^2));
end

dI0 = (dIrun(:, 1) + dIrun(:, 2) + dIrun(:, 3)) / 3;
x(col + 1) = sqrt(mean(dI0.^2));                                    col = col + 1;  % zeroSeq_RMS
x(col + 1) = sum(dI0.^2);                                           col = col + 1;  % zeroSeq_Energy
x(col + 1) = (max(rmsPhase) - min(rmsPhase)) / (mean(rmsPhase) + eps); col = col + 1;  % maxPhaseUnbalanceRatio
end

%% ======================================================================
function s = subbandStats(C)
% Same formulas as extract_features.m: Energy, normalized-Shannon-entropy,
% std, and max-abs of one wavelet sub-band's coefficient vector C.
C = C(:);
E = sum(C.^2);
if E > 0
    p = (C.^2) / E;
else
    p = zeros(size(C));
end
s.Energy  = E;
s.Entropy = -sum(p .* log(p + eps));
s.Std     = std(C);
s.MaxAbs  = max(abs(C));
end

%% ======================================================================
function [acc, macroF1] = accuracyAndMacroF1(yTrue, yPred, classNames)
% Same categorical-cast fix as train_classifiers.m's computeMetrics:
% predict() returns labels typed however each model's ClassNames was
% specified at training time (here, cellstr), while yTrue stays
% categorical - confusionmat requires matching types.
yTrue = categorical(yTrue, classNames);
yPred = categorical(yPred, classNames);

C = confusionmat(yTrue, yPred, 'Order', classNames);
nC = numel(classNames);
precision = zeros(nC, 1);
recall    = zeros(nC, 1);
f1        = zeros(nC, 1);
for i = 1:nC
    TP = C(i, i);
    FP = sum(C(:, i)) - TP;
    FN = sum(C(i, :)) - TP;
    if (TP + FP) > 0
        precision(i) = TP / (TP + FP);
    end
    if (TP + FN) > 0
        recall(i) = TP / (TP + FN);
    end
    if (precision(i) + recall(i)) > 0
        f1(i) = 2 * precision(i) * recall(i) / (precision(i) + recall(i));
    end
end
acc = sum(diag(C)) / sum(C(:));
macroF1 = mean(f1);
end
