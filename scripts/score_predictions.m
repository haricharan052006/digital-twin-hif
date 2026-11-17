function T = score_predictions(set)
%SCORE_PREDICTIONS  Scores every model's predictions of the journal comparison.
%
%   T = score_predictions('cv')    out-of-fold predictions results/dl/pred_<model>_cv.csv:
%                                  pooled over all folds, plus the mean and
%                                  standard deviation of the per-fold scores
%   T = score_predictions('test')  held-out test runs results/dl/pred_<model>_test[_seed<s>].csv:
%                                  every file, plus mean and standard deviation
%                                  over the seeds of each model
%
% Every metric comes from relay_window_metrics.m (one definition for RF,
% LightGBM and the 1D-CNN). Writes results/dl/scores_<set>.csv.

projectRoot = fileparts(fileparts(mfilename('fullpath')));
resDir = fullfile(projectRoot, 'results', 'dl');
W = readtable(fullfile(projectRoot, 'data', 'dl', 'windows.csv'), 'TextType', 'string');
metricNames = {'Accuracy', 'MacroF1', 'HifRecall', 'HifRecallWeak', 'FalseHifRate', 'Dependability', ...
    'DependabilityWeak', 'Security', 'FalseTrips', 'FalseTripsAdjacent', 'FalseTripsNormalSwitching', ...
    'FalseTripsPreInception', 'Sequences'};

files = dir(fullfile(resDir, sprintf('pred_*_%s*.csv', set)));
tok = regexp({files.name}, ['^pred_(.+)_' set '(?:_seed(\d+))?\.csv$'], 'tokens', 'once');
keep = ~cellfun(@isempty, tok);
files = files(keep);
tok = tok(keep);
models = unique(cellfun(@(t) string(t{1}), tok), 'stable');

rows = {};
for mdl = models
    sel = find(cellfun(@(t) string(t{1}) == mdl, tok));
    perUnit = [];                           % folds (cv) or seeds (test)
    for f = sel
        P = readtable(fullfile(resDir, files(f).name));
        Wp = W(P.row, :);
        assert(all(Wp.split == string(set) | (set == "cv" & Wp.split == "train")), ...
            '%s contains windows outside the %s set.', files(f).name, set);
        if set == "cv"
            assert(height(P) == nnz(W.split == "train"), '%s does not cover every training window.', files(f).name);
            rows(end + 1, :) = [{mdl, "pooled"}, struct2cell(pick(relay_window_metrics(Wp, P.pred), metricNames))']; %#ok<AGROW>
            for k = unique(P.fold)'
                in = P.fold == k;
                perUnit = [perUnit; pick(relay_window_metrics(Wp(in, :), P.pred(in)), metricNames)]; %#ok<AGROW>
            end
        else
            assert(height(P) == nnz(W.split == "test"), '%s does not cover every test window.', files(f).name);
            m = pick(relay_window_metrics(Wp, P.pred), metricNames);
            unit = "single";
            seedTok = regexp(files(f).name, '_seed(\d+)\.csv$', 'tokens', 'once');
            if ~isempty(seedTok)
                unit = "seed " + seedTok{1};
            end
            rows(end + 1, :) = [{mdl, unit}, struct2cell(m)']; %#ok<AGROW>
            perUnit = [perUnit; m]; %#ok<AGROW>
        end
    end
    if numel(perUnit) > 1
        A = cell2mat(cellfun(@(n) [perUnit.(n)]', metricNames, 'UniformOutput', false));   % units x metrics
        lbl = "seed";
        if set == "cv"
            lbl = "fold";
        end
        rows(end + 1, :) = [{mdl, lbl + " mean"}, num2cell(mean(A, 1, 'omitnan'))]; %#ok<AGROW>
        rows(end + 1, :) = [{mdl, lbl + " std"}, num2cell(std(A, 0, 1, 'omitnan'))]; %#ok<AGROW>
    end
end
T = cell2table(rows, 'VariableNames', [{'Model', 'Stat'}, metricNames]);
writetable(T, fullfile(resDir, sprintf('scores_%s.csv', set)));
end

%% ======================================================================
function s = pick(m, names)
for k = 1:numel(names)
    s.(names{k}) = m.(names{k});
end
end
