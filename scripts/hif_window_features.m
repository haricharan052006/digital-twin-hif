function [f, names] = hif_window_features(dIwin)
%HIF_WINDOW_FEATURES  db4 5-level DWT feature vector of one residual window.
%
%   f = hif_window_features(dIwin) returns a 1 x 87 feature row for one
%   window of 3-phase digital-twin residual current dIwin [N x 3] (A).
%   [f, names] = ... also returns the matching feature names.
%
% Shared by extract_features.m (offline training windows) and
% HIFRelayBlock.m (the in-model relay inside ieee13_hif_twin_system.slx),
% so the classifier always sees identically computed features.
%
% Per phase (A, B, C):
%   - 5-level 'db4' DWT (wavedec) -> sub-bands A5, D5, D4, D3, D2, D1. At
%     fs = 20 kHz the 60 Hz fundamental sits in A5 (0-312 Hz), so D1-D5
%     isolate the arc's harmonic / high-frequency non-linearity.
%   - For each sub-band: Energy sum(C.^2), normalized Shannon entropy,
%     Std, MaxAbs                                   (6 x 4 = 24)
%   - Time-domain Mean, Std, Skewness, Kurtosis of the window (CLAUDE.md)
%                                                     (4)
%   -> 28 per phase, 84 for A/B/C.
% Cross-phase (3): zero-sequence residual RMS and energy, and the
%   (max - min) / mean phase-RMS unbalance ratio.

WAVELET = 'db4';
LEVEL   = 5;
dIwin = double(dIwin);
nPer  = 28;
f = zeros(1, 3 * nPer + 3);
rmsPhase = zeros(1, 3);

col = 0;
for p = 1:3
    x = dIwin(:, p);
    [C, L] = wavedec(x, LEVEL, WAVELET);
    bands = cell(1, 6);
    bands{1} = appcoef(C, L, WAVELET, LEVEL);
    for lvl = LEVEL:-1:1
        bands{LEVEL - lvl + 2} = detcoef(C, L, lvl);
    end
    for b = 1:6
        c = bands{b};
        E = sum(c.^2);
        if E > 0
            pr = c.^2 / E;
        else
            pr = zeros(size(c));
        end
        f(col + (1:4)) = [E, -sum(pr .* log(pr + eps)), std(c), max(abs(c))];
        col = col + 4;
    end
    f(col + (1:4)) = [mean(x), std(x), safeSkew(x), safeKurt(x)];
    col = col + 4;
    rmsPhase(p) = sqrt(mean(x.^2));
end

dI0 = mean(dIwin, 2);
f(col + (1:3)) = [sqrt(mean(dI0.^2)), sum(dI0.^2), ...
    (max(rmsPhase) - min(rmsPhase)) / (mean(rmsPhase) + eps)];

if nargout > 1
    names = featureNames();
end
end

%% ======================================================================
function s = safeSkew(x)
% skewness() returns NaN for a constant window (zero variance, e.g. an
% exactly-zero residual); report 0 instead so the classifier never sees NaN.
s = skewness(x);
if ~isfinite(s)
    s = 0;
end
end

function k = safeKurt(x)
k = kurtosis(x);
if ~isfinite(k)
    k = 0;
end
end

%% ======================================================================
function names = featureNames()
phaseTags = {'A', 'B', 'C'};
bandTags  = {'A5', 'D5', 'D4', 'D3', 'D2', 'D1'};
statTags  = {'Energy', 'Entropy', 'Std', 'MaxAbs'};
timeTags  = {'Mean', 'Std', 'Skewness', 'Kurtosis'};
names = {};
for p = 1:3
    for b = 1:6
        for s = 1:4
            names{end + 1} = sprintf('phase%s_%s_%s', phaseTags{p}, bandTags{b}, statTags{s}); %#ok<AGROW>
        end
    end
    for s = 1:4
        names{end + 1} = sprintf('phase%s_time_%s', phaseTags{p}, timeTags{s}); %#ok<AGROW>
    end
end
names = [names, {'zeroSeq_RMS', 'zeroSeq_Energy', 'maxPhaseUnbalanceRatio'}];
end
