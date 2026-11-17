%% analyze_feature_importance.m
% Phase 5 (continued): Random Forest feature-importance analysis.
%
% 1. Loads the trained Random Forest (mdlRF) and the feature table
%    (X, featureNames) used to train it.
% 2. Computes out-of-bag permuted predictor importance
%    (oobPermutedPredictorImportance) - generally preferred over the
%    impurity-based predictorImportance since it isn't biased toward
%    high-cardinality/continuous predictors - falling back to
%    predictorImportance if OOB importance can't be computed for any
%    reason.
% 3. Ranks the top 15 features.
% 4. Plots them as a horizontal bar chart colored by feature type (Energy,
%    Entropy, Std, MaxAbs, Cross-Phase), saved to
%    results/feature_importance.png.
% 5. Groups importance by wavelet sub-band (A5/D5/D4/D3/D2/D1/Cross-Phase)
%    and by metric type (Energy/Entropy/Std/MaxAbs/Cross-Phase), to see
%    which frequency bands and statistics carry the strongest HIF
%    signature.
%
% Feature-name convention (from extract_features.m):
%   'phase<A/B/C>_<A5|D5|D4|D3|D2|D1>_<Energy|Entropy|Std|MaxAbs>'  (72)
%   'zeroSeq_RMS', 'zeroSeq_Energy', 'maxPhaseUnbalanceRatio'        (3,
%   all three grouped under sub-band AND metric-type category
%   'Cross-Phase' - none of them individually fits the per-phase
%   Energy/Entropy/Std/MaxAbs metric scheme, so rather than force one
%   arbitrarily into 'Energy' and strand the other two, all three share
%   one bucket in both groupings.)
%
% Input:  models/trained_classifiers.mat (mdlRF)
%         data/features.mat              (X, y, featureNames)
% Output: results/feature_importance.png
%
% Requires: Statistics and Machine Learning Toolbox.

%% ============================================================== setup
scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
dataDir     = fullfile(projectRoot, 'data');
modelsDir   = fullfile(projectRoot, 'models');
resultsDir  = fullfile(projectRoot, 'results');
if ~exist(resultsDir, 'dir')
    mkdir(resultsDir);
end

modelsFile   = fullfile(modelsDir, 'trained_classifiers.mat');
featuresFile = fullfile(dataDir, 'features.mat');
for f = {modelsFile, featuresFile}
    if ~isfile(f{1})
        error('analyze_feature_importance:InputMissing', ...
            '%s not found. Run the earlier pipeline scripts first.', f{1});
    end
end

fprintf('Loading %s and %s ...\n', modelsFile, featuresFile);
M = load(modelsFile, 'mdlRF', 'scaler');
F = load(featuresFile, 'X', 'featureNames');
mdlRF = M.mdlRF;
featureNames = F.featureNames;
Nfeat = numel(featureNames);

if isfield(M, 'scaler') && isfield(M.scaler, 'featureNames') ...
        && ~isequal(M.scaler.featureNames, featureNames)
    warning('analyze_feature_importance:FeatureNameMismatch', ...
        ['featureNames in %s does not match scaler.featureNames saved in %s - ' ...
         'the model may have been trained on a different feature.mat. Proceeding ' ...
         'anyway, but importance-to-name mapping may be wrong.'], featuresFile, modelsFile);
end

%% -------------------------------------------------- predictor importance
try
    imp = oobPermutedPredictorImportance(mdlRF);
    impMethod = 'Out-of-bag permuted predictor importance';
catch ME
    warning('analyze_feature_importance:OOBUnavailable', ...
        'oobPermutedPredictorImportance failed (%s); falling back to predictorImportance.', ...
        ME.message);
    imp = predictorImportance(mdlRF);
    impMethod = 'Predictor importance (impurity-based)';
end
imp = imp(:)';   % row vector

if numel(imp) ~= Nfeat
    error('analyze_feature_importance:SizeMismatch', ...
        'Importance vector has %d entries but featureNames has %d - model/feature mismatch.', ...
        numel(imp), Nfeat);
end
totalImp = sum(imp);

fprintf('  Importance method: %s\n', impMethod);

%% ------------------------------------------------- sub-band / type labels
% Every feature gets exactly one sub-band label and one type label. Type
% is Energy/Entropy/Std/MaxAbs for the 72 per-phase features, or
% 'Cross-Phase' for all 3 of zeroSeq_RMS/zeroSeq_Energy/maxPhaseUnbalanceRatio.
subbandOf = cell(Nfeat, 1);
typeOf    = cell(Nfeat, 1);

for i = 1:Nfeat
    nm = featureNames{i};
    tok = regexp(nm, '^phase[ABC]_(A5|D5|D4|D3|D2|D1)_(Energy|Entropy|Std|MaxAbs)$', ...
        'tokens', 'once');
    if ~isempty(tok)
        subbandOf{i} = tok{1};
        typeOf{i}    = tok{2};
    elseif any(strcmp(nm, {'zeroSeq_RMS', 'zeroSeq_Energy', 'maxPhaseUnbalanceRatio'}))
        subbandOf{i} = 'Cross-Phase';
        typeOf{i}    = 'Cross-Phase';
    else
        error('analyze_feature_importance:UnrecognizedFeatureName', ...
            'Feature name "%s" does not match the expected naming convention.', nm);
    end
end

%% ------------------------------------------------------------ top 15
[impSorted, order] = sort(imp, 'descend');
topN = min(15, Nfeat);
topIdx   = order(1:topN);
topNames = featureNames(topIdx);
topVals  = impSorted(1:topN);
topTypes = typeOf(topIdx);

fprintf('\n=== Top %d most discriminative features (Random Forest) ===\n', topN);
fprintf('| Rank | Feature | Sub-band | Type | Importance |\n');
fprintf('|---|---|---|---|---|\n');
for i = 1:topN
    fprintf('| %d | %s | %s | %s | %.6f |\n', i, topNames{i}, ...
        subbandOf{topIdx(i)}, topTypes{i}, topVals(i));
end

%% ----------------------------------------------------------- bar chart
typeCats   = {'Energy', 'Entropy', 'Std', 'MaxAbs', 'Cross-Phase'};
typeColors = [0.20 0.60 0.86;    % Energy - blue
              0.90 0.49 0.13;    % Entropy - orange
              0.17 0.63 0.17;    % Std - green
              0.84 0.15 0.16;    % MaxAbs - red
              0.58 0.40 0.74];   % Cross-Phase - purple

topColorIdx = cellfun(@(t) find(strcmp(typeCats, t)), topTypes);
topColors = typeColors(topColorIdx, :);

fig = figure('Visible', 'off', 'Position', [100 100 950 650]);
b = barh(flip(topVals));
b.FaceColor = 'flat';
b.CData = flip(topColors, 1);
yticks(1:topN);
yticklabels(flip(topNames));
ax = gca;
ax.TickLabelInterpreter = 'none';   % feature names contain underscores
xlabel(impMethod);
title(sprintf('Top %d Most Discriminative Features (Random Forest)', topN));
grid on;
box on;

hold on;
presentCats = typeCats(ismember(typeCats, unique(topTypes)));
legendHandles = gobjects(numel(presentCats), 1);
for c = 1:numel(presentCats)
    ci = strcmp(typeCats, presentCats{c});
    legendHandles(c) = patch(NaN, NaN, typeColors(ci, :));
end
legend(legendHandles, presentCats, 'Location', 'southeast');
hold off;

outPng = fullfile(resultsDir, 'feature_importance.png');
exportgraphics(fig, outPng, 'Resolution', 150);
close(fig);
fprintf('\nSaved: %s\n', outPng);

%% -------------------------------------------------- sub-band / type shares
subbandCats = {'A5', 'D5', 'D4', 'D3', 'D2', 'D1', 'Cross-Phase'};
fprintf('\n=== Importance by wavelet sub-band ===\n');
fprintf('| Sub-band | # Features | Total Importance | Mean Importance | Share |\n');
fprintf('|---|---|---|---|---|\n');
for c = 1:numel(subbandCats)
    mask = strcmp(subbandOf, subbandCats{c});
    s = sum(imp(mask));
    fprintf('| %s | %d | %.6f | %.6f | %.1f%% |\n', subbandCats{c}, nnz(mask), ...
        s, mean(imp(mask)), 100 * s / totalImp);
end

fprintf('\n=== Importance by metric type ===\n');
fprintf('| Type | # Features | Total Importance | Mean Importance | Share |\n');
fprintf('|---|---|---|---|---|\n');
for c = 1:numel(typeCats)
    mask = strcmp(typeOf, typeCats{c});
    s = sum(imp(mask));
    fprintf('| %s | %d | %.6f | %.6f | %.1f%% |\n', typeCats{c}, nnz(mask), ...
        s, mean(imp(mask)), 100 * s / totalImp);
end
