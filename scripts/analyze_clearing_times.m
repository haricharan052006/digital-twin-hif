function S = analyze_clearing_times()
%ANALYZE_CLEARING_TIMES  Summary tables and paper figures of the closed-loop
% clearing-time study (benchmark_clearing_times.m, journal comparison stage 4).
%
%   S = analyze_clearing_times() reads results/dl/clearing_times.csv and writes
%     results/dl/clearing_times_summary.csv   per relay x breaker time, over
%                                             the 32 HIF runs: dependability,
%                                             missed / sympathetic trips, and
%                                             median [min, max] of every stage
%     results/dl/clearing_times_decoys.csv    false trips in the decoy runs
%     results/report_figures/fig_dl_clearing_times.{pdf,png}
%     results/report_figures/fig_dl_clearing_example.{pdf,png}
% Run it in a batch worker (headless figure export).

projectRoot = fileparts(fileparts(mfilename('fullpath')));
resDir = fullfile(projectRoot, 'results', 'dl');
figDir = fullfile(projectRoot, 'results', 'report_figures');
opts = detectImportOptions(fullfile(resDir, 'clearing_times.csv'));
opts = setvartype(opts, {'scenario', 'bus', 'phase', 'tripped', 'relay', 'caseName'}, 'string');
T = readtable(fullfile(resDir, 'clearing_times.csv'), opts);
relays = ["RF", "LightGBM", "CNN wide"];
delays = [0 3 5];

H = T(T.scenario == "hif", :);
H.ok = ~H.missed & ~H.preInception;          % tripped the faulted lateral after inception
stages = {'trip_ms', 'detect_ms', 'confirm_ms', 'mechanical_ms', 'extinction_ms', 'clearing_ms', ...
    'interruption_ms', 'isolation_ms', 'clearing_cycles'};
rows = {};
for m = relays
    for d = delays
        R = H(H.relay == m & H.delayCycles == d, :);
        ok = R.ok & ~isnan(R.t4);
        row = {m, d, height(R), nnz(R.ok), nnz(R.missed), nnz(R.sympathetic), nnz(R.preInception), ...
            nnz(R.ok & isnan(R.t4))};
        for s = stages
            v = R.(s{1})(ok);
            row = [row, {median(v), min(v), max(v)}]; %#ok<AGROW>
        end
        rows(end + 1, :) = row; %#ok<AGROW>
    end
end
names = {'Relay', 'BreakerCycles', 'HifRuns', 'Cleared', 'Missed', 'Sympathetic', 'PreInception', 'NotExtinguished'};
for s = stages
    names = [names, strcat(s{1}, {'_median', '_min', '_max'})]; %#ok<AGROW>
end
S = cell2table(rows, 'VariableNames', names);
writetable(S, fullfile(resDir, 'clearing_times_summary.csv'));

D = T(T.scenario ~= "hif", {'relay', 'caseName', 'tripped', 'tripTime633', 'tripTime675'});
writetable(D, fullfile(resDir, 'clearing_times_decoys.csv'));

%% ------------------------------------------------ figure: clearing times
col = [0.165 0.471 0.839; 0.922 0.408 0.204; 0.106 0.686 0.478];
mk = {'o', 's', '^'};
fig = figure('Visible', 'off', 'Color', 'w', 'Units', 'inches', 'Position', [1 1 7.16 3.4]);
try
    theme(fig, 'light');
catch
end
tl = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

ax = nexttile(tl);
hold(ax, 'on');
xt = [];
for di = 1:numel(delays)
    for mi = 1:numel(relays)
        R = H(H.relay == relays(mi) & H.delayCycles == delays(di) & H.ok & ~isnan(H.t4), :);
        x = (di - 1) * 4 + mi;
        xt(end + 1) = x; %#ok<AGROW>
        jit = (mod((1:height(R))', 7) - 3) * 0.06;
        scatter(ax, x + jit, R.clearing_ms, 14, col(mi, :), mk{mi}, 'filled', 'MarkerFaceAlpha', 0.55, ...
            'HandleVisibility', 'off');
        if ~isempty(R)
            plot(ax, x + [-0.32 0.32], median(R.clearing_ms) * [1 1], 'k-', 'LineWidth', 1.4, 'HandleVisibility', 'off');
        end
        nMiss = nnz(H.relay == relays(mi) & H.delayCycles == delays(di) & ~H.ok);
        if nMiss > 0
            text(ax, x, 6, sprintf('%d\nmissed', nMiss), 'HorizontalAlignment', 'center', 'FontSize', 6.5, ...
                'Color', [0.35 0.35 0.35]);
        end
    end
end
for mi = 1:numel(relays)
    scatter(ax, nan, nan, 14, col(mi, :), mk{mi}, 'filled', 'DisplayName', relays(mi));
end
set(ax, 'XTick', [2 6 10], 'XTickLabel', {'0 cycles', '3 cycles', '5 cycles'}, 'XLim', [0 12], ...
    'FontName', 'Helvetica', 'FontSize', 8, 'Box', 'off', 'TickDir', 'out');
ylim(ax, [0 inf]);
grid(ax, 'on');
ax.GridAlpha = 0.15;
xlabel(ax, 'Breaker operating time');
ylabel(ax, 'Fault-clearing time, inception to arc extinction (ms)');
title(ax, '(a) Clearing time per run (bar = median)', 'FontWeight', 'normal', 'FontSize', 9);
legend(ax, 'Location', 'northwest', 'FontSize', 7.5, 'Box', 'off');

ax = nexttile(tl);
parts = {'detect_ms', 'confirm_ms', 'mechanical_ms', 'extinction_ms'};
labels = {'detection (t_1-t_0)', '2-of-3 confirmation (t_2-t_1)', 'breaker opening (t_3-t_2)', 'arc extinction (t_4-t_3)'};
M = zeros(numel(relays), numel(parts));
for mi = 1:numel(relays)
    R = H(H.relay == relays(mi) & H.delayCycles == 3 & H.ok & ~isnan(H.t4), :);
    for p = 1:numel(parts)
        M(mi, p) = median(R.(parts{p}));
    end
end
b = barh(ax, M, 'stacked', 'BarWidth', 0.6);
shades = [0.30 0.30 0.30; 0.55 0.55 0.55; 0.78 0.78 0.78; 0.12 0.12 0.12];
for p = 1:numel(parts)
    b(p).FaceColor = shades(p, :);
    b(p).EdgeColor = 'w';
    b(p).DisplayName = labels{p};
end
set(ax, 'YTick', 1:numel(relays), 'YTickLabel', relays, 'YDir', 'reverse', 'FontName', 'Helvetica', ...
    'FontSize', 8, 'Box', 'off', 'TickDir', 'out');
for mi = 1:numel(relays)
    text(ax, sum(M(mi, :)) + 1.5, mi, sprintf('\\Sigma %.1f ms', sum(M(mi, :))), 'FontSize', 7.5, ...
        'VerticalAlignment', 'middle');   % sum of stage medians, not the median total
end
xlim(ax, [0 1.25 * max(sum(M, 2))]);
xlabel(ax, 'Median time from inception (ms)');
title(ax, '(b) Median stage breakdown, 3-cycle breaker', 'FontWeight', 'normal', 'FontSize', 9);
lg = legend(ax, 'Location', 'southoutside', 'FontSize', 7, 'Box', 'off', 'NumColumns', 2);
lg.ItemTokenSize = [10 8];
exportgraphics(fig, fullfile(figDir, 'fig_dl_clearing_times.png'), 'Resolution', 300);
exportgraphics(fig, fullfile(figDir, 'fig_dl_clearing_times.pdf'), 'ContentType', 'vector');
close(fig);

%% ------------------------------------------------ figure: example timeline
E = load(fullfile(resDir, 'clearing_times_examples.mat'), 'ex');
ex = [E.ex{:}];
fig = figure('Visible', 'off', 'Color', 'w', 'Units', 'inches', 'Position', [1 1 7.16 4.2]);
try
    theme(fig, 'light');
catch
end
tl = tiledlayout(fig, numel(ex), 1, 'TileSpacing', 'compact', 'Padding', 'compact');
for k = 1:numel(ex)
    e = ex(k);
    ax = nexttile(tl);
    hold(ax, 'on');
    tm = 1e3 * (e.time - e.timeline.t0);
    plot(ax, tm, e.I_633, 'Color', [0.70 0.70 0.70], 'LineWidth', 0.6, 'HandleVisibility', 'off');
    plot(ax, tm, e.I_arc, 'Color', [0.80 0.15 0.15], 'LineWidth', 1.0, 'DisplayName', 'arc current');
    yl = [-1 1] * 1.1 * max(abs(e.I_633(:)));
    ylim(ax, yl);
    marks = {'t1', 'first HIF decision'; 't2', 'trip'; 't3', 'contacts part'; 't4', 'arc out'; 't5', 'isolation confirmed'};
    for q = 1:size(marks, 1)
        tq = 1e3 * (e.timeline.(marks{q, 1}) - e.timeline.t0);
        if isfinite(tq)
            xline(ax, tq, ':', 'Color', [0.2 0.2 0.2], 'HandleVisibility', 'off');
            if k == 1
                text(ax, tq, yl(2), [' ' marks{q, 2}], 'FontSize', 6.5, 'Rotation', 90, ...
                    'HorizontalAlignment', 'right', 'VerticalAlignment', 'top');
            end
        end
    end
    xlim(ax, [-10 120]);
    set(ax, 'FontName', 'Helvetica', 'FontSize', 8, 'Box', 'off', 'TickDir', 'out');
    ylabel(ax, 'A');
    title(ax, sprintf('%s relay - 633A typical arc, 3-cycle breaker: cleared %.1f ms after inception', ...
        e.relay, 1e3 * (e.timeline.t4 - e.timeline.t0)), 'FontWeight', 'normal', 'FontSize', 8.5);
    if k == numel(ex)
        xlabel(ax, 'Time from fault inception (ms)    grey: lateral 633 phase currents');
    end
end
exportgraphics(fig, fullfile(figDir, 'fig_dl_clearing_example.png'), 'Resolution', 300);
exportgraphics(fig, fullfile(figDir, 'fig_dl_clearing_example.pdf'), 'ContentType', 'vector');
close(fig);
end
