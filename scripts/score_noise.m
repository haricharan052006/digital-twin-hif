function T = score_noise()
%SCORE_NOISE  Measurement-noise robustness of every model of the journal comparison.
%
%   T = score_noise() scores results/dl/noise/pred_rf_sigma<i>.csv (deployed
%   relay RF, export_noisy_test.m) and pred_<model>_seed<s>_sigma<i>.csv
%   (LightGBM / 1D-CNN final models, dl/predict_noise.py) with
%   relay_window_metrics.m, and returns the mean and standard deviation over
%   seeds per model and sigma.
%
% Outputs: results/dl/noise_robustness_models.csv (mean / std over seeds),
%          results/dl/noise_robustness_models_long.csv (every model file),
%          results/report_figures/fig_dl_noise_robustness.{png,pdf}
%          results/report_figures/fig_dl_noise_augmented.{png,pdf} (clean vs
%          noise-augmented training, once the *_aug models are predicted)
% Run in a batch worker, e.g. batch(parcluster, @score_noise, 1, {}) - the
% figure export once blocked the interactive MCP MATLAB session.

projectRoot = fileparts(fileparts(mfilename('fullpath')));
resDir = fullfile(projectRoot, 'results', 'dl');
info = jsondecode(fileread(fullfile(projectRoot, 'data', 'dl', 'noise', 'noise.json')));
sigmas = info.sigmas(:)';
W = readtable(fullfile(projectRoot, 'data', 'dl', 'windows.csv'), 'TextType', 'string');
metricNames = {'Accuracy', 'MacroF1', 'HifRecall', 'HifRecallWeak', 'FalseHifRate', 'Dependability', ...
    'DependabilityWeak', 'Security', 'FalseTrips', 'FalseTripsAdjacent', 'FalseTripsNormalSwitching', ...
    'FalseTripsPreInception'};

files = dir(fullfile(resDir, 'noise', 'pred_*_sigma*.csv'));
long = {};
for f = files'
    % pred_<model>[_seed<s>]_sigma<i>.csv (MATLAB regexp does not capture
    % inside an optional group, so the suffixes are parsed one at a time)
    base = regexprep(f.name, '_sigma\d+\.csv$', '');
    i = str2double(regexp(f.name, '_sigma(\d+)\.csv$', 'tokens', 'once'));
    seedTok = regexp(base, '_seed(\d+)$', 'tokens', 'once');
    seed = NaN;   % the single deployed RF
    if ~isempty(seedTok)
        seed = str2double(seedTok{1});
    end
    model = string(regexprep(regexprep(base, '^pred_', ''), '_seed\d+$', ''));
    P = readtable(fullfile(f.folder, f.name));
    m = relay_window_metrics(W(P.row, :), P.pred);
    long(end + 1, :) = [{model, seed, sigmas(i)}, cellfun(@(n) m.(n), metricNames, 'UniformOutput', false)]; %#ok<AGROW>
end
L = cell2table(long, 'VariableNames', [{'Model', 'Seed', 'Sigma_A'}, metricNames]);
L = sortrows(L, {'Model', 'Sigma_A', 'Seed'});
writetable(L, fullfile(resDir, 'noise_robustness_models_long.csv'));

[G, model, sigma] = findgroups(L.Model, L.Sigma_A);
T = table(model, sigma, splitapply(@numel, L.Seed, G), 'VariableNames', {'Model', 'Sigma_A', 'Seeds'});
for n = metricNames
    T.(n{1}) = splitapply(@mean, L.(n{1}), G);
    T.([n{1} '_std']) = splitapply(@(v) std(v, 0), L.(n{1}), G);
end
writetable(T, fullfile(resDir, 'noise_robustness_models.csv'));

outDir = fullfile(projectRoot, 'results', 'report_figures');
blue = [0.165 0.471 0.839];
orange = [0.922 0.408 0.204];
green = [0.106 0.686 0.478];
spec = {   % model, legend name, colour, marker, line style
    "rf",           'Random Forest (deployed)',     blue,   'o', '-'
    "lgbm",         'LightGBM',                     orange, 's', '-'
    "cnn_wide_ref", '1D-CNN, wide receptive field', green,  '^', '-'
    "cnn_ref",      '1D-CNN, base receptive field', [0.537 0.529 0.506], 'v', '--'};
plot_noise_figure(T, sigmas, outDir, spec, 'fig_dl_noise_robustness');
% Clean-trained (dashed, open markers) vs noise-augmented training (solid).
specAug = {
    "rf",               'RF, clean training',            blue,   'o', '--'
    "rf_aug",           'RF, noise-augmented',           blue,   'o', '-'
    "lgbm",             'LightGBM, clean',               orange, 's', '--'
    "lgbm_aug",         'LightGBM, noise-augmented',     orange, 's', '-'
    "cnn_wide_ref",     'CNN wide, clean',               green,  '^', '--'
    "cnn_wide_ref_aug", 'CNN wide, noise-augmented',     green,  '^', '-'};
if any(T.Model == "rf_aug")
    plot_noise_figure(T, sigmas, outDir, specAug, 'fig_dl_noise_augmented');
end
end

%% ======================================================================
function plot_noise_figure(T, sigmas, outDir, spec, name)
% Paper figure (IEEE double-column width, light theme, vector PDF + 300 dpi
% PNG) of the models in spec {model, legend, colour, marker, line style}.
% Error bars = standard deviation over the three training seeds. Marker
% shape and line style repeat the colour coding for print and colour-vision
% deficiency; dashed lines get open markers. Render it in a batch worker
% (headless): in the interactive MCP session exportgraphics once blocked
% the session.
panels = {'Dependability', '(a) Fault detection, 2-of-3 vote', 'Detected faults (%)', 100
          'DependabilityWeak', '(b) Weak-arc fault detection', 'Detected weak arcs (%)', 100
          'FalseTrips', '(c) False trips', 'False trips (of 360 sequences)', 1
          'FalseHifRate', '(d) Non-HIF windows classified HIF', 'False-HIF windows (%)', 100};
xs = sigmas;
xs(1) = 0.0025;   % sigma = 0 drawn at the left edge of the log axis
tickLabels = [{'0'}, arrayfun(@(s) sprintf('%g', s), sigmas(2:end), 'UniformOutput', false)];

fig = figure('Visible', 'off', 'Color', 'w', 'Units', 'inches', 'Position', [1 1 7.16 5.4]);
try
    theme(fig, 'light');
catch
end
tl = tiledlayout(fig, 2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
h = gobjects(0);
for p = 1:size(panels, 1)
    ax = nexttile(tl);
    hold(ax, 'on');
    for k = 1:size(spec, 1)
        r = T.Model == spec{k, 1};
        if ~any(r)
            continue;
        end
        s = panels{p, 4};
        face = spec{k, 3};
        if strcmp(spec{k, 5}, '--') && size(spec, 1) == 6
            face = 'w';   % open markers for the clean-trained lines of the comparison figure
        end
        e = errorbar(ax, xs, s * T.(panels{p, 1})(r), s * T.([panels{p, 1} '_std'])(r), ...
            'LineStyle', spec{k, 5}, 'Marker', spec{k, 4}, 'Color', spec{k, 3}, ...
            'MarkerFaceColor', face, 'MarkerSize', 4.5, 'LineWidth', 1.2, 'CapSize', 3, ...
            'DisplayName', spec{k, 2});
        if p == 1
            h(end + 1) = e; %#ok<AGROW>
        end
    end
    set(ax, 'XScale', 'log', 'XTick', xs, 'XTickLabel', tickLabels, 'XLim', [0.002 0.6], ...
        'FontName', 'Helvetica', 'FontSize', 8, 'Box', 'off', 'TickDir', 'out', 'LineWidth', 0.6, ...
        'XMinorTick', 'off', 'XMinorGrid', 'off');
    if panels{p, 4} == 100 && ~strcmp(panels{p, 1}, 'FalseHifRate')
        ylim(ax, [0 100]);
    else
        ylim(ax, [0 inf]);   % counts and rates: a seed error bar never pulls the axis below zero
    end
    grid(ax, 'on');
    ax.GridAlpha = 0.15;
    title(ax, panels{p, 2}, 'FontWeight', 'normal', 'FontSize', 9);
    ylabel(ax, panels{p, 3});
    xlabel(ax, 'Noise \it\sigma\rm per phase (A)');
end
lg = legend(h, 'Orientation', 'horizontal', 'FontSize', 8, 'Box', 'off', 'NumColumns', min(4, numel(h)));
if numel(h) == 6
    lg.NumColumns = 3;
end
lg.Layout.Tile = 'north';
exportgraphics(fig, fullfile(outDir, [name '.png']), 'Resolution', 300);
exportgraphics(fig, fullfile(outDir, [name '.pdf']), 'ContentType', 'vector');
close(fig);
end
