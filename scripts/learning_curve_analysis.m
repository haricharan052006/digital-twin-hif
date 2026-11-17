function S = learning_curve_analysis()
%LEARNING_CURVE_ANALYSIS  Scores the learning-curve predictions
% (dl/learning_curve.py, learning_curve_rf.m) on the 180 held-out test runs
% with relay_window_metrics.m and draws the paper figure.
%
%   S = learning_curve_analysis() returns mean and standard deviation over
%   the three repeats per model and training fraction, and writes
%     results/dl/learning_curve_summary.csv
%     results/dl/learning_curve_runs.csv        one row per prediction file
%     results/report_figures/fig_dl_learning_curve.{pdf,png}
% The noise-augmented wide CNN (720 runs, clean windows + two noisy copies
% each) is added as a separate reference point. Also reports a power-law fit
% of the CNN's missed-fault rate against training runs - an extrapolation,
% labelled as such. Run in a batch worker (headless figure export).

projectRoot = fileparts(fileparts(mfilename('fullpath')));
lcDir = fullfile(projectRoot, 'results', 'dl', 'learning_curve');
W = readtable(fullfile(projectRoot, 'data', 'dl', 'windows.csv'), 'TextType', 'string');
Sub = readtable(fullfile(lcDir, 'subsets.csv'));

files = dir(fullfile(lcDir, 'pred_*_f*_r*.csv'));
rows = {};
for k = 1:numel(files)
    t = regexp(files(k).name, '^pred_(.+)_f(\d+)_r(\d+)\.csv$', 'tokens', 'once');
    f = str2double(t{2});
    r = str2double(t{3});
    P = readtable(fullfile(files(k).folder, files(k).name));
    m = relay_window_metrics(W(P.row, :), P.pred);
    rows(end + 1, :) = {string(t{1}), f, r, nRuns(Sub, f, r), m.MacroF1, m.Accuracy, m.HifRecall, ...
        m.Dependability, m.DependabilityWeak, m.FalseTrips}; %#ok<AGROW>
end
L = cell2table(rows, 'VariableNames', {'Model', 'Fraction', 'Repeat', 'TrainRuns', 'MacroF1', 'Accuracy', ...
    'HifRecall', 'Dependability', 'DependabilityWeak', 'FalseTrips'});
L = sortrows(L, {'Model', 'Fraction', 'Repeat'});
writetable(L, fullfile(projectRoot, 'results', 'dl', 'learning_curve_runs.csv'));

[G, model, frac] = findgroups(L.Model, L.Fraction);
S = table(model, frac, splitapply(@mean, L.TrainRuns, G), 'VariableNames', {'Model', 'Fraction', 'TrainRuns'});
for v = {'MacroF1', 'Dependability', 'DependabilityWeak', 'FalseTrips', 'HifRecall'}
    S.(v{1}) = splitapply(@mean, L.(v{1}), G);
    S.([v{1} '_std']) = splitapply(@(x) std(x, 0), L.(v{1}), G);
end
writetable(S, fullfile(projectRoot, 'results', 'dl', 'learning_curve_summary.csv'));
disp(S);

% noise-augmented CNN reference point (720 runs, 3x windows)
T = score_predictions('test');
aug = T(string(T.Model) == "cnn_wide_ref_aug" & ismember(string(T.Stat), ["seed mean", "seed std"]), :);

% power-law extrapolation of the CNN's missed-fault rate: 1 - dep = a * n^-b
c = S(S.Model == "cnn_wide_ref", :);
p = polyfit(log(c.TrainRuns), log(1 - c.Dependability), 1);
target = 1 - S.Dependability(S.Model == "lgbm" & S.Fraction == 100);
nNeeded = exp((log(target) - p(2)) / p(1));
fprintf('CNN power-law fit: missed-fault rate ~ n^%.2f; reaching LightGBM''s %.1f %% detection would need ~%.0f training runs (extrapolation)\n', ...
    p(1), 100 * (1 - target), nNeeded);
fid = fopen(fullfile(projectRoot, 'results', 'dl', 'learning_curve_fit.json'), 'w');
fprintf(fid, '%s', jsonencode(struct('cnn_missed_rate_exponent', p(1), 'cnn_missed_rate_log_intercept', p(2), ...
    'lgbm_full_dependability', 1 - target, 'cnn_runs_needed_extrapolated', nNeeded)));
fclose(fid);

%% ---------------------------------------------------------------- figure
spec = {"rf", 'Random Forest', [0.165 0.471 0.839], 'o'
        "lgbm", 'LightGBM', [0.922 0.408 0.204], 's'
        "cnn_wide_ref", '1D-CNN, wide', [0.106 0.686 0.478], '^'};
panels = {'MacroF1', '(a) Macro F1, window level', 'Macro F1', 1
          'Dependability', '(b) Fault detection, 2-of-3 vote', 'Detected faults (%)', 100
          'DependabilityWeak', '(c) Weak-arc fault detection', 'Detected weak arcs (%)', 100};
fig = figure('Visible', 'off', 'Color', 'w', 'Units', 'inches', 'Position', [1 1 7.16 2.9]);
try
    theme(fig, 'light');
catch
end
tl = tiledlayout(fig, 1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
h = gobjects(0);
for q = 1:size(panels, 1)
    ax = nexttile(tl);
    hold(ax, 'on');
    sc = panels{q, 4};
    for k = 1:size(spec, 1)
        s = S(S.Model == spec{k, 1}, :);
        e = errorbar(ax, s.TrainRuns, sc * s.(panels{q, 1}), sc * s.([panels{q, 1} '_std']), '-', ...
            'Marker', spec{k, 4}, 'Color', spec{k, 3}, 'MarkerFaceColor', spec{k, 3}, 'MarkerSize', 4.5, ...
            'LineWidth', 1.2, 'CapSize', 3, 'DisplayName', spec{k, 2});
        if q == 1
            h(end + 1) = e; %#ok<AGROW>
        end
    end
    if ~isempty(aug)
        va = aug.(panels{q, 1});
        e = errorbar(ax, 745, sc * va(1), sc * va(2), 'Marker', 'p', 'LineStyle', 'none', ...   % 720 runs, drawn offset
            'Color', [0.106 0.686 0.478], 'MarkerFaceColor', 'w', 'MarkerSize', 7, 'LineWidth', 1.2, ...
            'DisplayName', '1D-CNN, wide, + 2 noisy copies per window');
        if q == 1
            h(end + 1) = e; %#ok<AGROW>
        end
    end
    set(ax, 'XTick', [180 360 540 720], 'XLim', [140 775], 'FontName', 'Helvetica', 'FontSize', 8, ...
        'Box', 'off', 'TickDir', 'out');
    grid(ax, 'on');
    ax.GridAlpha = 0.15;
    xlabel(ax, 'Training runs');
    ylabel(ax, panels{q, 3});
    title(ax, panels{q, 2}, 'FontWeight', 'normal', 'FontSize', 9);
end
lg = legend(h, 'Orientation', 'horizontal', 'FontSize', 8, 'Box', 'off');
lg.Layout.Tile = 'north';
outDir = fullfile(projectRoot, 'results', 'report_figures');
exportgraphics(fig, fullfile(outDir, 'fig_dl_learning_curve.png'), 'Resolution', 300);
exportgraphics(fig, fullfile(outDir, 'fig_dl_learning_curve.pdf'), 'ContentType', 'vector');
close(fig);
end

%% ======================================================================
function n = nRuns(Sub, f, r)
% Training runs in the subset of fraction f (%) of repeat r.
if f == 100
    n = nnz(Sub.repeat == r);
else
    n = nnz(Sub.repeat == r & Sub.(sprintf('in%d', f)) == 1);
end
end
