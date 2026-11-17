%% benchmark_latency.m
% Real-time inference latency benchmark for the trained HIF classifiers.
%
% Measures, over 1,000 iterations each:
%   (a) DWT (db4, 5-level) feature extraction time for one window
%       (model-independent - same 75-feature extraction feeds all models).
%   (b) Model prediction time alone, per model (SVM, Random Forest, MLP),
%       given an already-extracted, already-standardized feature vector.
%   (c) Total end-to-end detection latency per model: a fresh feature
%       extraction + standardization + prediction, timed together as one
%       block - what an actual relay loop would do every cycle.
% Reports mean and P99 for each, in milliseconds, against the standard
% power-system protection benchmark of 1 cycle at 60 Hz (~16.67 ms).
%
% IMPORTANT CAVEAT this benchmark surfaces rather than hides: the 75
% features these models were trained on (extract_features.m) are computed
% over the FULL residual window generate_dataset.m simulated -
% T_STOP = 0.30 s = 6001 samples at Ts = 50e-6 s (CLAUDE.md's 20 kHz
% sampling rate). That is the window length benchmarked below. Even if
% compute time is negligible, a relay cannot classify a fault before it
% has ACQUIRED 300 ms of post-inception data - about 18 cycles at 60 Hz,
% not the 1 cycle a true instantaneous protection element targets. That
% acquisition-window latency is a property of the feature design, not of
% how fast the code runs, and no amount of code optimization changes it;
% meeting a true 1-cycle target would require redesigning the feature
% pipeline around a much shorter sliding window (e.g. 1-2 cycles), which
% is out of scope for this benchmark but is flagged here explicitly so it
% isn't mistaken for something this script's numbers already solve.
%
% Input:  models/trained_classifiers.mat (mdlSVM, mdlRF, mdlNN, scaler)
%         data/raw_residuals.mat         (dI - for one realistic input window)
% Output: Markdown table to stdout only (no file artifacts).
%
% Requires: Wavelet Toolbox, Statistics and Machine Learning Toolbox.

%% ============================================================== setup
scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
dataDir     = fullfile(projectRoot, 'data');
modelsDir   = fullfile(projectRoot, 'models');

rawFile    = fullfile(dataDir, 'raw_residuals.mat');
modelsFile = fullfile(modelsDir, 'trained_classifiers.mat');
for f = {rawFile, modelsFile}
    if ~isfile(f{1})
        error('benchmark_latency:InputMissing', ...
            '%s not found. Run the earlier pipeline scripts first.', f{1});
    end
end

fprintf('Loading %s and %s ...\n', rawFile, modelsFile);
R = load(rawFile, 'dI');
Mdl = load(modelsFile, 'mdlSVM', 'mdlRF', 'mdlNN', 'scaler');
mdlSVM = Mdl.mdlSVM;
mdlRF  = Mdl.mdlRF;
mdlNN  = Mdl.mdlNN;
scaler = Mdl.scaler;

WAVELET = 'db4';
LEVEL   = 5;
subbandTags = {'A5', 'D5', 'D4', 'D3', 'D2', 'D1'};
statTags    = {'Energy', 'Entropy', 'Std', 'MaxAbs'};

dISample = R.dI(:, :, 1);   % one representative real 3-phase residual window
Ts = 50e-6;
Nsamples = size(dISample, 1);
windowMs = (Nsamples - 1) * Ts * 1000;
fprintf('  Benchmark window: %d samples @ Ts=%.1f us -> %.2f ms of acquired data\n', ...
    Nsamples, Ts * 1e6, windowMs);

CYCLE_MS = 1000 / 60;   % 1 cycle at 60 Hz, ~16.667 ms
NITER = 1000;

%% ------------------------------------------------------------- warm-up
% First-call JIT/compile overhead is excluded from the timed loops.
xWarm = extractFeatureVector(dISample, WAVELET, LEVEL, subbandTags, statTags);
xzWarm = (xWarm - scaler.mu) ./ scaler.sigma;
predict(mdlSVM, xzWarm);
predict(mdlRF,  xzWarm);
predict(mdlNN,  xzWarm);

%% ============================================ (a) feature extraction only
fprintf('\n=== (a) DWT feature extraction (model-independent, %d iterations) ===\n', NITER);
tFeat = zeros(NITER, 1);
for it = 1:NITER
    t0 = tic;
    x = extractFeatureVector(dISample, WAVELET, LEVEL, subbandTags, statTags); %#ok<NASGU>
    tFeat(it) = toc(t0);
end
tFeatMs = tFeat * 1000;
fprintf('  mean = %.4f ms, P99 = %.4f ms\n', mean(tFeatMs), prctile(tFeatMs, 99));

xFeat = extractFeatureVector(dISample, WAVELET, LEVEL, subbandTags, statTags);
xz = (xFeat - scaler.mu) ./ scaler.sigma;

%% ================================================ (b) prediction only
fprintf('\n=== (b) Model prediction only (pre-extracted feature vector, %d iterations) ===\n', NITER);
models = {mdlSVM, mdlRF, mdlNN};
modelNames = {'SVM', 'Random Forest', 'MLP'};
tPredMs = zeros(NITER, 3);

for m = 1:3
    t = zeros(NITER, 1);
    for it = 1:NITER
        t0 = tic;
        predict(models{m}, xz);
        t(it) = toc(t0);
    end
    tPredMs(:, m) = t * 1000;
    fprintf('  %-15s mean = %.4f ms, P99 = %.4f ms\n', modelNames{m}, ...
        mean(tPredMs(:, m)), prctile(tPredMs(:, m), 99));
end

%% ============================================ (c) total end-to-end latency
fprintf('\n=== (c) End-to-end latency (feature extraction + classification, %d iterations) ===\n', NITER);
tEndToEndMs = zeros(NITER, 3);

for m = 1:3
    t = zeros(NITER, 1);
    for it = 1:NITER
        t0 = tic;
        xE = extractFeatureVector(dISample, WAVELET, LEVEL, subbandTags, statTags);
        xzE = (xE - scaler.mu) ./ scaler.sigma;
        predict(models{m}, xzE);
        t(it) = toc(t0);
    end
    tEndToEndMs(:, m) = t * 1000;
    fprintf('  %-15s mean = %.4f ms, P99 = %.4f ms\n', modelNames{m}, ...
        mean(tEndToEndMs(:, m)), prctile(tEndToEndMs(:, m), 99));
end

%% ================================================== Markdown summary table
fprintf('\n## Real-Time Inference Latency Benchmark\n\n');
fprintf('Window: %d samples (%.2f ms of acquired data). 1-cycle @ 60 Hz threshold = %.3f ms.\n\n', ...
    Nsamples, windowMs, CYCLE_MS);
fprintf('| Stage | Model | Mean (ms) | P99 (ms) | Meets 1-cycle (%.2f ms)? |\n', CYCLE_MS);
fprintf('|---|---|---|---|---|\n');
fprintf('| DWT feature extraction | (shared) | %.4f | %.4f | %s |\n', ...
    mean(tFeatMs), prctile(tFeatMs, 99), passFail(prctile(tFeatMs, 99), CYCLE_MS));
for m = 1:3
    fprintf('| Prediction only | %s | %.4f | %.4f | %s |\n', modelNames{m}, ...
        mean(tPredMs(:, m)), prctile(tPredMs(:, m), 99), ...
        passFail(prctile(tPredMs(:, m), 99), CYCLE_MS));
end
for m = 1:3
    fprintf('| End-to-end | %s | %.4f | %.4f | %s |\n', modelNames{m}, ...
        mean(tEndToEndMs(:, m)), prctile(tEndToEndMs(:, m), 99), ...
        passFail(prctile(tEndToEndMs(:, m), 99), CYCLE_MS));
end

fprintf(['\n**Note:** the table above reflects COMPUTE time only. The 75 features ' ...
    'are extracted from a %.0f ms window (%d samples), so real-world detection ' ...
    'latency is at minimum window-acquisition time (%.0f ms, ~%.1f cycles) plus the ' ...
    'compute time above - not the compute time alone. Meeting a genuine 1-cycle\n' ...
    '(%.2f ms) protection-grade target would require redesigning the feature ' ...
    'pipeline around a much shorter sliding window; that is a data-design change, ' ...
    'not a code-speed optimization.\n'], windowMs, Nsamples, windowMs, ...
    windowMs / CYCLE_MS, CYCLE_MS);

%% ======================================================================
function s = passFail(valMs, thresholdMs)
if valMs <= thresholdMs
    s = 'Yes';
else
    s = 'No';
end
end

%% ======================================================================
function x = extractFeatureVector(dIrun, WAVELET, LEVEL, subbandTags, statTags)
% Identical to extract_features.m: builds one run's 75-element feature row
% (phase A/B/C x 6 sub-bands x 4 stats, then 3 cross-phase features).
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
