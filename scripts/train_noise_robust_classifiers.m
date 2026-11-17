%% train_noise_robust_classifiers.m
% Noise-augmented retraining experiment: does training on AWGN-perturbed
% (+ lightly denoised) residuals let SVM and MLP recover the noise
% resilience that test_noise_robustness.m showed collapsing without
% test-time wavelet denoising?
%
% Design:
%   1. Reproduce the IDENTICAL stratified train/test split used by
%      train_classifiers.m (same rng(rngSeed) + cvpartition call), so the
%      held-out test runs are exactly the same ones the original models
%      were evaluated on - required for a fair before/after comparison.
%   2. Build an augmented training set = [clean features; noise-augmented
%      features] for the SAME training runs (doubling the training rows,
%      not replacing them) - each training run contributes one clean
%      feature row and one perturbed feature row, so the retrained models
%      see both regimes rather than only noisy data.
%      Perturbation per training run: AWGN at sigma = 0.02 A on each
%      phase, followed by LIGHT wavelet soft-thresholding - a shallow
%      2-level wdenoise (wdenoise's default ThresholdRule is 'Soft'),
%      deliberately shallower than the full 5-level wdenoise used as the
%      test-time fix in test_noise_robustness.m, so this is training-time
%      data augmentation, not a full denoising pipeline the model would
%      depend on at inference time.
%   3. A fresh z-score scaler is fit on the augmented training set (reusing
%      the original scaler would be wrong - the augmented feature
%      distribution differs from the original).
%   4. Re-fit SVM/RF/MLP with the same hyperparameters as
%      train_classifiers.m for a like-for-like comparison.
%   5. Evaluate BOTH the original (clean-trained) and new (noise-augmented)
%      models across the sigma = [0, 0.01, 0.05, 0.1, 0.2, 0.5, 1.0] A test
%      sweep - deliberately WITHOUT any test-time denoising this time, to
%      isolate whether training-time augmentation alone (no test-time
%      wavelet-denoising crutch) restores resilience.
%
% Input:  data/raw_residuals.mat         (dI, labels)
%         models/trained_classifiers.mat (original mdlSVM/mdlRF/mdlNN,
%                                          scaler, classNames, rngSeed -
%                                          for split reproduction and the
%                                          "before" comparison curve)
% Output: models/trained_classifiers_noise_robust.mat
%         results/noise_augmented_comparison.png
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
        error('train_noise_robust_classifiers:InputMissing', ...
            '%s not found. Run the earlier pipeline scripts first.', f{1});
    end
end

fprintf('Loading %s and %s ...\n', rawFile, modelsFile);
R = load(rawFile, 'dI', 'labels');
Orig = load(modelsFile, 'mdlSVM', 'mdlRF', 'mdlNN', 'scaler', 'classNames', 'rngSeed');

dI = R.dI;
labels = R.labels;
mdlSVMorig = Orig.mdlSVM;
mdlRForig  = Orig.mdlRF;
mdlNNorig  = Orig.mdlNN;
scalerOrig = Orig.scaler;
classNames = Orig.classNames;
rngSeed    = Orig.rngSeed;

WAVELET = 'db4';
LEVEL   = 5;
subbandTags = {'A5', 'D5', 'D4', 'D3', 'D2', 'D1'};
statTags    = {'Energy', 'Entropy', 'Std', 'MaxAbs'};
AUG_SIGMA = 0.02;   % Amperes - training-time noise floor

%% -------------------------------------------- reproduce the train/test split
rng(rngSeed);
try
    cv = cvpartition(labels, 'HoldOut', 0.20, 'Stratify', true);
catch
    cv = cvpartition(labels, 'HoldOut', 0.20);
end
idxTrain = training(cv);
idxTest  = test(cv);

dITrain = dI(:, :, idxTrain);
ytrain  = labels(idxTrain);
dITest  = dI(:, :, idxTest);
ytest   = labels(idxTest);
Ntrain  = numel(ytrain);
Ntest   = numel(ytest);
fprintf('  Reproduced split: %d train / %d test\n', Ntrain, Ntest);

%% -------------------------------------- build clean + noise-augmented training features
fprintf('\n=== Building augmented training set (%d clean + %d noise-augmented rows) ===\n', ...
    Ntrain, Ntrain);
rng(rngSeed);   % deterministic augmentation noise, reproducible across reruns

XtrainClean = nan(Ntrain, 75);
XtrainAug   = nan(Ntrain, 75);

for k = 1:Ntrain
    dIrun = dITrain(:, :, k);
    XtrainClean(k, :) = extractFeatureVector(dIrun, WAVELET, LEVEL, subbandTags, statTags);

    dIaug = zeros(size(dIrun));
    for p = 1:3
        dIaug(:, p) = augmentPhase(dIrun(:, p), AUG_SIGMA, WAVELET);
    end
    XtrainAug(k, :) = extractFeatureVector(dIaug, WAVELET, LEVEL, subbandTags, statTags);

    if mod(k, 100) == 0 || k == Ntrain
        fprintf('  %d / %d training runs featurized (clean + augmented)\n', k, Ntrain);
    end
end

Xcombined = [XtrainClean; XtrainAug];
ycombined = [ytrain; ytrain];

%% ----------------------------------------------- fresh scaler (augmented set)
mu = mean(Xcombined, 1);
sigma = std(Xcombined, 0, 1);
sigma(sigma == 0) = 1;
XcombinedZ = (Xcombined - mu) ./ sigma;

scalerAug.mu = mu;
scalerAug.sigma = sigma;

%% ============================================================ retrain models
fprintf('\n=== Retraining on the noise-augmented set ===\n');

fprintf('  [1/3] SVM (ECOC, Gaussian/RBF, KernelScale auto) ...\n');
tSVM = templateSVM('KernelFunction', 'gaussian', 'KernelScale', 'auto', 'Standardize', false);
mdlSVMaug = fitcecoc(XcombinedZ, ycombined, 'Learners', tSVM, 'ClassNames', classNames);

fprintf('  [2/3] Random Forest (bagged trees, 100 learners) ...\n');
tTree = templateTree('Reproducible', true);
mdlRFaug = fitcensemble(XcombinedZ, ycombined, 'Method', 'Bag', 'NumLearningCycles', 100, ...
    'Learners', tTree, 'ClassNames', classNames);

fprintf('  [3/3] Feedforward MLP (fitcnet, 2 hidden layers) ...\n');
mdlNNaug = fitcnet(XcombinedZ, ycombined, 'LayerSizes', [50 30], 'Activations', 'relu', ...
    'Standardize', false, 'ClassNames', classNames);

%% ==================================================== comparison sweep
% Deliberately NO test-time denoising here (unlike test_noise_robustness.m)
% - this isolates whether training-time augmentation alone restores
% resilience, without leaning on a test-time wavelet-denoising step.
noiseLevels = [0, 0.01, 0.05, 0.1, 0.2, 0.5, 1.0];
noiseLabels = {'Clean', '0.01A', '0.05A', '0.1A', '0.2A', '0.5A', '1.0A'};
nLevels = numel(noiseLevels);

accOrig = zeros(nLevels, 3);   % columns: SVM, RF, MLP
accAug  = zeros(nLevels, 3);

rng(rngSeed);   % deterministic test-time noise draws, reproducible across reruns

fprintf('\n=== Comparison sweep: original (clean-trained) vs noise-augmented models ===\n');
for s = 1:nLevels
    sigma_s = noiseLevels(s);
    Xnoisy = nan(Ntest, 75);
    for k = 1:Ntest
        dIrun = dITest(:, :, k);
        dINoisy = dIrun + sigma_s * randn(size(dIrun));
        Xnoisy(k, :) = extractFeatureVector(dINoisy, WAVELET, LEVEL, subbandTags, statTags);
    end

    XnoisyZorig = (Xnoisy - scalerOrig.mu) ./ scalerOrig.sigma;
    XnoisyZaug  = (Xnoisy - scalerAug.mu) ./ scalerAug.sigma;

    accOrig(s, 1) = quickAccuracy(mdlSVMorig, XnoisyZorig, ytest, classNames);
    accOrig(s, 2) = quickAccuracy(mdlRForig,  XnoisyZorig, ytest, classNames);
    accOrig(s, 3) = quickAccuracy(mdlNNorig,  XnoisyZorig, ytest, classNames);

    accAug(s, 1) = quickAccuracy(mdlSVMaug, XnoisyZaug, ytest, classNames);
    accAug(s, 2) = quickAccuracy(mdlRFaug,  XnoisyZaug, ytest, classNames);
    accAug(s, 3) = quickAccuracy(mdlNNaug,  XnoisyZaug, ytest, classNames);

    fprintf(['  sigma = %-6s :  SVM  orig=%.4f aug=%.4f  |  RF  orig=%.4f aug=%.4f  ' ...
        '|  MLP orig=%.4f aug=%.4f\n'], noiseLabels{s}, ...
        accOrig(s,1), accAug(s,1), accOrig(s,2), accAug(s,2), accOrig(s,3), accAug(s,3));
end

%% ----------------------------------------------------------------- plot
xCat = categorical(noiseLabels, noiseLabels);
modelNames = {'SVM', 'Random Forest', 'MLP'};
colors = [0.20 0.60 0.86; 0.90 0.49 0.13; 0.17 0.63 0.17];

fig = figure('Visible', 'off', 'Position', [100 100 900 650]);
hold on;
for m = 1:3
    plot(xCat, accOrig(:, m), '--o', 'Color', colors(m, :), 'LineWidth', 1.3, ...
        'MarkerSize', 6, 'DisplayName', sprintf('%s (original, clean-trained)', modelNames{m}));
end
for m = 1:3
    plot(xCat, accAug(:, m), '-s', 'Color', colors(m, :), 'LineWidth', 2, ...
        'MarkerSize', 7, 'MarkerFaceColor', colors(m, :), ...
        'DisplayName', sprintf('%s (noise-augmented)', modelNames{m}));
end
hold off;
grid on;
box on;
ylim([0 1.05]);
xlabel('Injected test-time CT noise (\sigma, Amperes), no test-time denoising');
ylabel('Test Accuracy');
title('Noise-Augmented Retraining: Original vs. Noise-Augmented Models');
legend('Location', 'southwest', 'NumColumns', 2);

outPng = fullfile(resultsDir, 'noise_augmented_comparison.png');
exportgraphics(fig, outPng, 'Resolution', 150);
close(fig);
fprintf('\nSaved: %s\n', outPng);

%% --------------------------------------------------------------------- save
results.noiseLevels = noiseLevels;
results.noiseLabels = noiseLabels;
results.accOrig = accOrig;
results.accAug  = accAug;
results.modelNames = modelNames;
results.augSigma = AUG_SIGMA;

outFile = fullfile(modelsDir, 'trained_classifiers_noise_robust.mat');
save(outFile, 'mdlSVMaug', 'mdlRFaug', 'mdlNNaug', 'scalerAug', 'results', ...
    'classNames', 'rngSeed', '-v7.3');
fprintf('Saved: %s\n', outFile);

%% ================================================== Markdown summary table
fprintf('\n## Noise-Augmented Retraining - Test Accuracy (Original vs. Augmented)\n\n');
fprintf('| Noise sigma | SVM orig | SVM aug | RF orig | RF aug | MLP orig | MLP aug |\n');
fprintf('|---|---|---|---|---|---|---|\n');
for s = 1:nLevels
    fprintf('| %s | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f |\n', noiseLabels{s}, ...
        accOrig(s,1), accAug(s,1), accOrig(s,2), accAug(s,2), accOrig(s,3), accAug(s,3));
end

%% ======================================================================
function xAug = augmentPhase(xp, sigma, WAVELET)
% AWGN at a fixed absolute standard deviation (Amperes), followed by
% LIGHT wavelet soft-thresholding: a shallow 2-level wdenoise (default
% ThresholdRule is 'Soft'), deliberately shallower than the full 5-level
% wdenoise used as the test-time fix in test_noise_robustness.m.
xNoisy = xp + sigma * randn(size(xp));
xAug = wdenoise(xNoisy, 2, 'Wavelet', WAVELET);
end

%% ======================================================================
function acc = quickAccuracy(mdl, Xz, yTrue, classNames)
pred = categorical(predict(mdl, Xz), classNames);
yTrue = categorical(yTrue, classNames);
acc = mean(pred == yTrue);
end

%% ======================================================================
function x = extractFeatureVector(dIrun, WAVELET, LEVEL, subbandTags, statTags)
% Identical to extract_features.m / test_noise_robustness.m: builds one
% run's 75-element feature row (phase A/B/C x 6 sub-bands x 4 stats, then
% 3 cross-phase features), same column order throughout the pipeline.
Nperphase = numel(subbandTags) * numel(statTags);
x = nan(1, 3 * Nperphase + 3);
col = 0;
rmsPhase = zeros(1, 3);

for p = 1:3
    xp = dIrun(:, p);
    [C, L] = wavedec(xp, LEVEL, WAVELET);

    subbands = cell(1, 6);
    subbands{1} = appcoef(C, L, WAVELET, LEVEL);
    for lvl = LEVEL:-1:1
        subbands{LEVEL - lvl + 2} = detcoef(C, L, lvl);
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
x(col + 1) = sqrt(mean(dI0.^2));                                    col = col + 1;
x(col + 1) = sum(dI0.^2);                                           col = col + 1;
x(col + 1) = (max(rmsPhase) - min(rmsPhase)) / (mean(rmsPhase) + eps); col = col + 1;
end

%% ======================================================================
function s = subbandStats(C)
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
