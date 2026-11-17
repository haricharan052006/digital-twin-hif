%% extract_features.m
% Phase 4: windowed 5-level db4 DWT feature extraction from the lateral
% digital-twin residual currents, matching what the in-model HIF relays
% (HIFRelayBlock.m in ieee13_hif_twin_system.slx) see in real time.
%
% Each relay watches ONE lateral-head residual dI = I_physical - I_twin
% (dI633L for lateral 632-633, dI675L for lateral 692-675) through a
% sliding window of WINDOW_LEN samples (2 cycles at 20 kHz). Training
% samples are therefore windows, not whole runs: every run contributes
% windows from both laterals, stepped by HOP_LEN (1 cycle), starting at
% T_START (skips the first cycle of each run). Features per window come
% from hif_window_features.m (shared with the relay block).
%
% Window labels:
%   HIF run, the FAULTED lateral: windows ending before inception -> Normal;
%     windows starting at/after inception -> HIF_Phase_<ph>; windows that
%     straddle inception are dropped (half-and-half, no single true label).
%   HIF run, the OTHER lateral: every window -> Normal. That relay must not
%     trip for a fault on the neighbouring lateral (selectivity).
%   Switching run: windows overlapping [tSwitch, tSwitch + SWITCH_SPAN]
%     -> Switching_Transient; all other windows -> Normal (the post-switch
%     steady state is a benign operating condition).
%   Normal run: every window -> Normal.
%
% Input:  data/raw_residuals.mat (generate_dataset.m), plus
%         data/raw_residuals_boundary.mat (generate_dataset('boundary'),
%         weak near-limit HIF runs) appended as runs 751.. when present.
% Output: data/features.mat containing
%   X            [Nwin x 87] double         feature matrix
%   y            [Nwin x 1] categorical     Normal | Switching_Transient |
%                                           HIF_Phase_A | HIF_Phase_B | HIF_Phase_C
%   runIdx       [Nwin x 1] double          source run (for grouped splits)
%   runSource    [Nwin x 1] categorical     main | boundary dataset
%   lateral      [Nwin x 1] categorical     633 | 675
%   tStart       [Nwin x 1] double          window start time (s)
%   featureNames [1 x 87] cell
%   WINDOW_LEN, HOP_LEN, Ts
%
% Requires: Wavelet Toolbox, Statistics and Machine Learning Toolbox.

%% ============================================================== setup
scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
dataDir     = fullfile(projectRoot, 'data');
inFile      = fullfile(dataDir, 'raw_residuals.mat');
boundaryFile = fullfile(dataDir, 'raw_residuals_boundary.mat');
outFile     = fullfile(dataDir, 'features.mat');

WINDOW_LEN  = 667;      % samples = 2 cycles at 20 kHz (must match HIFRelayBlock)
HOP_LEN     = 334;      % samples = 1 cycle
T_START     = 1/60;     % s, first window start
SWITCH_SPAN = 3/60;     % s, switching-transient labelling span after the event

if ~isfile(inFile)
    error('extract_features:InputMissing', ...
        '%s not found. Run scripts/generate_dataset.m first.', inFile);
end

fprintf('Loading %s ...\n', inFile);
S = load(inFile, 'dI633L', 'dI675L', 'labels', 'meta', 'tGrid', 'Ts');
sourceOfRun = repmat("main", numel(S.meta), 1);
if isfile(boundaryFile)
    fprintf('Appending %s ...\n', boundaryFile);
    B = load(boundaryFile, 'dI633L', 'dI675L', 'meta', 'tGrid');
    if ~isequal(B.tGrid, S.tGrid)
        error('extract_features:GridMismatch', 'Boundary dataset uses a different time grid.');
    end
    S.dI633L = cat(3, S.dI633L, B.dI633L);
    S.dI675L = cat(3, S.dI675L, B.dI675L);
    S.meta = [S.meta(:); B.meta(:)];
    sourceOfRun = [sourceOfRun; repmat("boundary", numel(B.meta), 1)];
    clear B
end
tGrid = S.tGrid;
Ts = S.Ts;
Nruns = numel(S.meta);
laterals = {'633', '675'};
residuals = {S.dI633L, S.dI675L};

starts = find(tGrid >= T_START, 1):HOP_LEN:(numel(tGrid) - WINDOW_LEN + 1);
winT0 = tGrid(starts);
winT1 = tGrid(starts + WINDOW_LEN - 1);
nPerRun = numel(starts);

[~, featureNames] = hif_window_features(zeros(WINDOW_LEN, 3));
nFeat = numel(featureNames);
nMax = Nruns * numel(laterals) * nPerRun;
X       = zeros(nMax, nFeat);
yStr    = strings(nMax, 1);
runIdx  = zeros(nMax, 1);
latStr  = strings(nMax, 1);
tStart  = zeros(nMax, 1);
keep    = false(nMax, 1);

%% ======================================================= per-window extraction
fprintf('Extracting %d-sample windows (hop %d) from %d runs x 2 laterals ...\n', ...
    WINDOW_LEN, HOP_LEN, Nruns);
reportEvery = max(1, round(Nruns / 10));
row = 0;
for k = 1:Nruns
    m = S.meta(k);
    for L = 1:numel(laterals)
        winLabels = labelWindows(m, laterals{L}, winT0, winT1, SWITCH_SPAN);
        for w = 1:nPerRun
            row = row + 1;
            if winLabels(w) == ""
                continue;   % straddles HIF inception - no single true label
            end
            seg = residuals{L}(starts(w):starts(w) + WINDOW_LEN - 1, :, k);
            X(row, :) = hif_window_features(seg);
            yStr(row) = winLabels(w);
            runIdx(row) = k;
            latStr(row) = laterals{L};
            tStart(row) = winT0(w);
            keep(row) = true;
        end
    end
    if mod(k, reportEvery) == 0 || k == Nruns
        fprintf('  %d / %d runs done\n', k, Nruns);
    end
end

X = X(keep, :);
classNames = ["Normal", "Switching_Transient", "HIF_Phase_A", "HIF_Phase_B", "HIF_Phase_C"];
y = categorical(yStr(keep), classNames);
runIdx = runIdx(keep);
lateral = categorical(latStr(keep), string(laterals));
tStart = tStart(keep);
runSource = categorical(sourceOfRun(runIdx), ["main", "boundary"]);

%% -------------------------------------------------------------- sanity checks
nNaN = nnz(isnan(X));
nInf = nnz(isinf(X));
fprintf('\n=== Feature matrix summary ===\n');
fprintf('  X size:      [%d x %d]  (Nwindows x Nfeatures)\n', size(X, 1), size(X, 2));
fprintf('  NaN entries: %d, Inf entries: %d\n', nNaN, nInf);
fprintf('  Class counts (lateral 633 / 675):\n');
for c = categories(y)'
    fprintf('    %-20s %6d  (%d / %d)\n', c{1}, nnz(y == c{1}), ...
        nnz(y == c{1} & lateral == '633'), nnz(y == c{1} & lateral == '675'));
end
if nNaN > 0 || nInf > 0
    warning('extract_features:NonFiniteValues', ...
        'X contains %d NaN and %d Inf entries - inspect before training.', nNaN, nInf);
end

%% --------------------------------------------------------------------- save
fprintf('  Windows from boundary runs: %d\n', nnz(runSource == 'boundary'));
save(outFile, 'X', 'y', 'runIdx', 'runSource', 'lateral', 'tStart', 'featureNames', ...
    'WINDOW_LEN', 'HOP_LEN', 'Ts', '-v7.3');
fprintf('\nSaved to: %s\n', outFile);

%% ======================================================================
function lbl = labelWindows(m, lateralBus, winT0, winT1, switchSpan)
% Per-window label for one run seen from one lateral ("" = drop window).
lbl = repmat("Normal", numel(winT0), 1);
switch m.type
    case 'HIF'
        if strcmp(m.bus, lateralBus)
            lbl(:) = "";
            lbl(winT1 < m.tIncept) = "Normal";
            lbl(winT0 >= m.tIncept) = "HIF_Phase_" + m.phase;
        end
    case 'Switching_Transient'
        overlaps = winT1 >= m.switchTime & winT0 <= m.switchTime + switchSpan;
        lbl(overlaps) = "Switching_Transient";
end
end
