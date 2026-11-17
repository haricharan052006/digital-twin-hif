%% train_classifiers.m
% Phase 5: Classifier training & evaluation for the windowed lateral HIF
% relay (features from extract_features.m / hif_window_features.m).
%
% Pipeline:
%   1. Load data/features.mat (X, y, runIdx, lateral, featureNames).
%   2. GROUPED 80/20 train/test split BY SIMULATION RUN (cvpartition over
%      runs, stratified by each run's event class). Windows overlap by one
%      cycle and every run yields ~30 windows, so a window-level split would
%      put near-identical windows from one run on both sides and inflate
%      every score.
%   3. Z-score standardization fit on the TRAINING windows only.
%   4. Train three architectures on the training windows:
%        - Random Forest:   fitcensemble('Method','Bag', 100 trees) - the
%          CLAUDE.md primary engine, also deployed as the in-model relay.
%          5-fold CV is GROUPED by run (folds built over training runs).
%          USE_CLASS_WEIGHTS (default false) optionally trains with inverse
%          class-frequency observation weights. Tried and rejected for the
%          relay: it raised Switching_Transient recall (0.86 -> 0.93) but
%          also the false-HIF window rate (0.26% -> 0.96%), and in closed
%          loop a 633C fault then sympathetically tripped the healthy 675
%          lateral (verify_twin_isolation.m 9/12 vs 10/12 unweighted).
%        - Multiclass SVM:  fitcecoc + templateSVM('KernelFunction','gaussian')
%        - Feedforward MLP: fitcnet
%      (SVM and MLP are evaluated on the held-out test runs only.)
%   5. Evaluate on the held-out test runs: multiclass accuracy, macro +
%      per-class precision/recall/F1, and the relay decision itself - HIF
%      (any phase) vs non-HIF - with its own accuracy / recall / false-trip
%      rate. Confusion-matrix figure per model.
%   6. Save all models + metrics + scaler to models/trained_classifiers.mat,
%      and the deployable relay bundle (compact RF + scaler + window
%      settings) to models/hif_relay_model.mat for HIFRelayBlock.m.
%
% Input:  data/features.mat
% Output: models/trained_classifiers.mat, models/hif_relay_model.mat,
%         results/confusion_matrix_{RandomForest,SVM,NeuralNetwork}.png
%
% Requires: Statistics and Machine Learning Toolbox.

%% ============================================================== setup
rngSeed = 42;
rng(rngSeed);

% Inverse class-frequency weighting of the Random Forest (see header): off.
USE_CLASS_WEIGHTS = false;

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
dataDir     = fullfile(projectRoot, 'data');
modelsDir   = fullfile(projectRoot, 'models');
resultsDir  = fullfile(projectRoot, 'results');
if ~exist(resultsDir, 'dir')
    mkdir(resultsDir);
end

inFile = fullfile(dataDir, 'features.mat');
if ~isfile(inFile)
    error('train_classifiers:InputMissing', ...
        '%s not found. Run scripts/extract_features.m first.', inFile);
end

fprintf('Loading %s ...\n', inFile);
S = load(inFile, 'X', 'y', 'runIdx', 'lateral', 'featureNames', 'WINDOW_LEN', 'HOP_LEN', 'Ts');
X = S.X;
y = S.y;
runIdx = S.runIdx;
featureNames = S.featureNames;
classNames = categories(y);
fprintf('  X: [%d x %d] windows from %d runs, classes: %s\n', size(X, 1), size(X, 2), ...
    numel(unique(runIdx)), strjoin(classNames, ', '));

%% ------------------------------------------- grouped 80/20 split by run
runs = unique(runIdx);
runKind = runEventClass(y, runIdx, runs);
cvRuns = cvpartition(runKind, 'HoldOut', 0.20, 'Stratify', true);
testRuns = runs(test(cvRuns));
idxTest  = ismember(runIdx, testRuns);
idxTrain = ~idxTest;

Xtrain = X(idxTrain, :);  ytrain = y(idxTrain);  runTrain = runIdx(idxTrain);
Xtest  = X(idxTest, :);   ytest  = y(idxTest);
fprintf('  Train: %d windows / %d runs, Test: %d windows / %d runs\n', ...
    nnz(idxTrain), numel(runs) - numel(testRuns), nnz(idxTest), numel(testRuns));

%% -------------------------------------------- standardize (train-set only)
mu = mean(Xtrain, 1);
sigma = std(Xtrain, 0, 1);
sigma(sigma == 0) = 1;   % guard against constant/degenerate features
XtrainZ = (Xtrain - mu) ./ sigma;
XtestZ  = (Xtest - mu) ./ sigma;

scaler.mu = mu;
scaler.sigma = sigma;
scaler.featureNames = featureNames;

%% ======================================================= train
fprintf('\n=== Training models ===\n');

fprintf('  [1/3] Random Forest (bagged trees, 100 learners) ...\n');
tTree = templateTree('Reproducible', true);
if USE_CLASS_WEIGHTS
    rfWeights = @(yt) inverseClassFrequencyWeights(yt);
else
    rfWeights = @(yt) ones(numel(yt), 1);
end
trainRF = @(Xt, yt) fitcensemble(Xt, yt, 'Method', 'Bag', 'NumLearningCycles', 100, ...
    'Learners', tTree, 'ClassNames', classNames, 'Weights', rfWeights(yt));
mdlRF = trainRF(XtrainZ, ytrain);

% Grouped 5-fold CV over the training runs.
trainRuns = unique(runTrain);
trainKind = runEventClass(ytrain, runTrain, trainRuns);
cvFolds = cvpartition(trainKind, 'KFold', 5, 'Stratify', true);
nCorrect = 0;
for fold = 1:cvFolds.NumTestSets
    inFold = ismember(runTrain, trainRuns(test(cvFolds, fold)));
    mdlFold = trainRF(XtrainZ(~inFold, :), ytrain(~inFold));
    pred = categorical(predict(mdlFold, XtrainZ(inFold, :)), classNames);
    nCorrect = nCorrect + nnz(pred == ytrain(inFold));
end
cvAccRF = nCorrect / numel(ytrain);
fprintf('        grouped 5-fold CV accuracy: %.4f\n', cvAccRF);

fprintf('  [2/3] Multiclass SVM (ECOC, Gaussian/RBF kernel) ...\n');
% KernelScale 'auto': the default of 1 is far too tight for ~90 z-scored
% features (every point looks equidistant).
tSVM = templateSVM('KernelFunction', 'gaussian', 'KernelScale', 'auto', 'Standardize', false);
mdlSVM = fitcecoc(XtrainZ, ytrain, 'Learners', tSVM, 'ClassNames', classNames);

fprintf('  [3/3] Feedforward MLP (fitcnet, 2 hidden layers) ...\n');
mdlNN = fitcnet(XtrainZ, ytrain, 'LayerSizes', [50 30], 'Activations', 'relu', ...
    'Standardize', false, 'ClassNames', classNames);

%% ======================================================= test-set evaluation
fprintf('\n=== Evaluating on the held-out test runs ===\n');
predRF  = predict(mdlRF,  XtestZ);
predSVM = predict(mdlSVM, XtestZ);
predNN  = predict(mdlNN,  XtestZ);

metricsRF  = computeMetrics(ytest, predRF,  classNames);
metricsSVM = computeMetrics(ytest, predSVM, classNames);
metricsNN  = computeMetrics(ytest, predNN,  classNames);
metricsRF.CVAccuracy  = cvAccRF;
metricsSVM.CVAccuracy = NaN;
metricsNN.CVAccuracy  = NaN;

saveConfusionChart(ytest, predRF, classNames, 'Random Forest (100 trees) - test runs', ...
    fullfile(resultsDir, 'confusion_matrix_RandomForest.png'));
saveConfusionChart(ytest, predSVM, classNames, 'SVM (ECOC, Gaussian kernel) - test runs', ...
    fullfile(resultsDir, 'confusion_matrix_SVM.png'));
saveConfusionChart(ytest, predNN, classNames, 'Feedforward MLP - test runs', ...
    fullfile(resultsDir, 'confusion_matrix_NeuralNetwork.png'));
fprintf('  Confusion matrix figures saved to %s\n', resultsDir);

%% --------------------------------------------------------------------- save
results.RandomForest  = metricsRF;
results.SVM           = metricsSVM;
results.NeuralNetwork = metricsNN;
results.testRuns      = testRuns;

outFile = fullfile(modelsDir, 'trained_classifiers.mat');
save(outFile, 'mdlSVM', 'mdlRF', 'mdlNN', 'scaler', 'results', 'classNames', 'rngSeed', '-v7.3');
fprintf('\nSaved trained models + metrics + scaler to: %s\n', outFile);

% Deployable relay bundle for HIFRelayBlock.m (compact RF only).
relayModel = compact(mdlRF);
windowLen  = S.WINDOW_LEN;
hopLen     = S.HOP_LEN;
Ts         = S.Ts;
relayFile = fullfile(modelsDir, 'hif_relay_model.mat');
save(relayFile, 'relayModel', 'scaler', 'classNames', 'featureNames', 'windowLen', 'hopLen', 'Ts');
fprintf('Saved relay bundle (compact RF + scaler) to: %s\n', relayFile);

%% ================================================== Markdown summary tables
fprintf('\n## Test-run comparison (grouped split; RF CV is grouped 5-fold)\n\n');
fprintf('| Model | CV Accuracy | Test Accuracy | Macro F1 | HIF-vs-rest Accuracy | HIF Recall | False-trip Rate |\n');
fprintf('|---|---|---|---|---|---|---|\n');
printModelRow('Random Forest (100 trees)', metricsRF);
printModelRow('SVM (RBF, ECOC)', metricsSVM);
printModelRow('Feedforward MLP', metricsNN);
printPerClassTable('Random Forest (100 trees)', metricsRF, classNames);

%% ======================================================================
function w = inverseClassFrequencyWeights(y)
% Observation weights 1 / (count of the observation's class), scaled so the
% weights sum to numel(y): every class contributes the same total weight.
[~, ~, idx] = unique(y);
counts = accumarray(idx, 1);
w = 1 ./ counts(idx);
w = w * numel(y) / sum(w);
end

%% ======================================================================
function kind = runEventClass(y, runIdx, runs)
% One stratification label per run: its HIF phase class if any window is
% HIF, else Switching_Transient if any window is, else Normal.
kind = strings(numel(runs), 1);
for i = 1:numel(runs)
    yr = y(runIdx == runs(i));
    hif = yr(startsWith(string(yr), "HIF"));
    if ~isempty(hif)
        kind(i) = string(hif(1));
    elseif any(yr == 'Switching_Transient')
        kind(i) = "Switching_Transient";
    else
        kind(i) = "Normal";
    end
end
kind = categorical(kind);
end

%% ======================================================================
function m = computeMetrics(yTrue, yPred, classNames)
% Confusion matrix (fixed class order), accuracy, per-class and macro
% precision/recall/F1, plus the relay's binary HIF-vs-rest decision.
% predict() returns cellstr for cellstr ClassNames, so both sides are cast
% to categorical over the same class set before comparing.
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

isHifTrue = startsWith(string(yTrue), "HIF");
isHifPred = startsWith(string(yPred), "HIF");

m.ConfusionMatrix   = C;
m.ClassNames        = classNames;
m.Accuracy          = sum(diag(C)) / sum(C(:));
m.PerClassPrecision = precision;
m.PerClassRecall    = recall;
m.PerClassF1        = f1;
m.MacroPrecision    = mean(precision);
m.MacroRecall       = mean(recall);
m.MacroF1           = mean(f1);
m.HifAccuracy       = mean(isHifTrue == isHifPred);
m.HifRecall         = nnz(isHifTrue & isHifPred) / max(1, nnz(isHifTrue));
m.FalseTripRate     = nnz(~isHifTrue & isHifPred) / max(1, nnz(~isHifTrue));
end

%% ======================================================================
function saveConfusionChart(yTrue, yPred, classNames, titleStr, outFile)
yTrue = categorical(yTrue, classNames);
yPred = categorical(yPred, classNames);
fig = figure('Visible', 'off', 'Position', [100 100 760 620]);
confusionchart(yTrue, yPred, 'Title', titleStr, ...
    'RowSummary', 'row-normalized', 'ColumnSummary', 'column-normalized');
exportgraphics(fig, outFile, 'Resolution', 150);
close(fig);
end

%% ======================================================================
function printModelRow(name, m)
fprintf('| %s | %.4f | %.4f | %.4f | %.4f | %.4f | %.4f |\n', name, m.CVAccuracy, ...
    m.Accuracy, m.MacroF1, m.HifAccuracy, m.HifRecall, m.FalseTripRate);
end

%% ======================================================================
function printPerClassTable(name, m, classNames)
fprintf('\n### %s - per-class metrics\n\n', name);
fprintf('| Class | Precision | Recall | F1 |\n');
fprintf('|---|---|---|---|\n');
for i = 1:numel(classNames)
    fprintf('| %s | %.4f | %.4f | %.4f |\n', ...
        classNames{i}, m.PerClassPrecision(i), m.PerClassRecall(i), m.PerClassF1(i));
end
end
