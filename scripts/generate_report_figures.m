function generate_report_figures(steps)
%GENERATE_REPORT_FIGURES  Capture every figure used in the final capstone
% report into results/report_figures/ (PNG), plus report_numbers.mat with
% the measured values quoted in the text.
%
%   generate_report_figures            % all steps
%   generate_report_figures({'canvas', 'proof'})   % selected steps
%
% Steps: canvas, oneline, architecture, arc, proof, run10s, scope, manual,
% wavelet, ml, delays, dataset, speed, dashboard, live. Each step is independent
% and wrapped in try/catch so one failure does not stop the rest. All
% simulations are run in memory (models are closed without saving).
% The 'scope' and 'manual' steps plot the two Scope_Isolated_Current signals
% (logged I_633L and I_675L) in the scope's two-display layout on a white
% background (the report uses a light theme throughout).

allSteps = {'canvas', 'oneline', 'architecture', 'arc', 'proof', 'run10s', 'scope', 'manual', ...
    'wavelet', 'ml', 'delays', 'dataset', 'speed', 'dashboard', 'live'};
if nargin < 1 || isempty(steps)
    steps = allSteps;
end
root = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root, 'scripts'), fullfile(root, 'models'));
figDir = fullfile(root, 'results', 'report_figures');
if ~exist(figDir, 'dir')
    mkdir(figDir);
end
numFile = fullfile(figDir, 'report_numbers.mat');
if isfile(numFile)
    N = load(numFile);
else
    N = struct();
end
for k = 1:numel(steps)
    fprintf('--- %s ---\n', steps{k});
    t0 = tic;
    try
        N = feval(['step_' steps{k}], root, figDir, N);
        save(numFile, '-struct', 'N');
        fprintf('    done (%.0f s)\n', toc(t0));
    catch e
        fprintf(2, '    FAILED: %s\n', getReport(e, 'basic'));
    end
    bdclose('all');
    close all force;
end
end

%% ======================================================================
function N = step_canvas(root, figDir, N)
% High-resolution canvas prints. The functional groups are outlined with
% area annotations added IN MEMORY only: the model is never saved here (the
% caller closes it with bdclose), so the .slx file does not contain them.
sys = 'ieee13_hif_twin_system';
load_system(fullfile(root, 'models', [sys '.slx']));
pf = [sys '/Physical_Feeder'];
dt = [sys '/Digital_Twin'];
red = [1 0.80 0.80]; yel = [1 0.94 0.62]; grn = [0.80 0.95 0.80]; blu = [0.82 0.90 1]; vio = [0.92 0.85 1];
tri = @(f) arrayfun(@(p) sprintf(f, p), 'ABC', 'UniformOutput', false);
nl = newline;
fs = 20;
addArea(sys, {'dI_650', 'dI_633L', 'dI_675L'}, 'RESIDUALS', [1 0.92 0.70], fs);
addArea(sys, {'HIF_Relay_633'}, 'HIF RELAY 633', blu, fs);
addArea(sys, {'HIF_Relay_675'}, 'HIF RELAY 675', blu, fs);
addArea(sys, {'One_633', 'CloseCmd_633', 'BrkCmd_633'}, 'SELECTOR 633', grn, fs);
addArea(sys, {'One_675', 'CloseCmd_675', 'BrkCmd_675'}, 'SELECTOR 675', grn, fs);
addArea(sys, {'Control_Mode', 'Control_Mode_Switch', 'Manual_Trip_633', 'Manual_Trip_633_Switch', ...
    'Manual_Trip_675', 'Manual_Trip_675_Switch'}, 'OPERATOR PANEL', vio, fs, 28);
print(['-s' sys], '-dpng', '-r250', fullfile(figDir, 'fig_canvas_toplevel.png'));
fs = 30;
addArea(pf, [tri('FaultBreaker_633%c'), tri('Emanuel_Arc_Fault_633%c'), tri('FaultGnd_633%c')], ...
    'HIF BRANCHES BUS 633', red, fs);
addArea(pf, [tri('FaultBreaker_675%c'), tri('Emanuel_Arc_Fault_675%c'), tri('FaultGnd_675%c')], ...
    'HIF BRANCHES BUS 675', red, fs);
addArea(pf, {'LoadStepBrk_671', 'LoadStepA_671', 'LoadStepB_671', 'LoadStepC_671'}, ...
    'DECOY LoadStepBrk_671', yel, fs);
addArea(pf, {'CapBrk_611C', 'Cap611C'}, ['DECOY' nl 'CapBrk_611C'], yel, fs);
addArea(pf, {'CapBrk_675'}, ['DECOY' nl 'CapBrk_675'], yel, fs);
addArea(pf, {'Brk_632_633', 'VI_633L'}, 'LATERAL BRK 633', grn, fs);
addArea(pf, {'Brk_692_675', 'VI_675L'}, 'LATERAL BRK 675', grn, fs);
addArea(pf, {'Src_650', 'VI_650'}, 'SOURCE 650', blu, fs);
print(['-s' pf], '-dpng', '-r220', fullfile(figDir, 'fig_canvas_physical_feeder.png'));
addArea(dt, {'Brk_632_633', 'VI_633L'}, 'MIRRORED BRK 633', grn, fs);
addArea(dt, {'Brk_692_675', 'VI_675L'}, 'MIRRORED BRK 675', grn, fs);
addArea(dt, [{'XFM_633_634'}, tri('L634%c')], 'LOADS 633-634', blu, fs);
addArea(dt, [tri('L675%c'), tri('Cap675%c')], 'LOADS + BANK 675', blu, fs);
addArea(dt, {'Src_650', 'VI_650'}, 'SOURCE 650', blu, fs);
addNote(dt, ['HEALTHY REFERENCE: no FaultBreaker / Emanuel arc branches,' nl ...
    'no CapBrk_675, CapBrk_611C or LoadStepBrk_671 switching devices'], [0.33 0.25], fs);
print(['-s' dt], '-dpng', '-r220', fullfile(figDir, 'fig_canvas_digital_twin.png'));
load_system(fullfile(root, 'models', 'emanuel_arc_subsystem.slx'));
print('-semanuel_arc_subsystem/Emanuel_Arc_Fault', '-dpng', '-r220', fullfile(figDir, 'fig_canvas_emanuel_arc.png'));
% (a subsystem's own find_system result includes the subsystem; the model's does not)
N.canvas.blocksTop = numel(find_system(sys, 'SearchDepth', 1, 'Type', 'Block'));
N.canvas.blocksPhysical = numel(find_system([sys '/Physical_Feeder'], 'SearchDepth', 1, 'Type', 'Block')) - 1;
N.canvas.blocksTwin = numel(find_system([sys '/Digital_Twin'], 'SearchDepth', 1, 'Type', 'Block')) - 1;
end

%% ======================================================================
function N = step_oneline(~, figDir, N)
fig = lightFig([100 100 1200 820]);
ax = axes(fig, 'Position', [0.02 0.02 0.96 0.92]);
hold(ax, 'on'); axis(ax, 'off'); axis(ax, 'equal');
P = containers.Map( ...
    {'650', '632', '633', '634', '645', '646', '671', '684', '611', '652', '680', '692', '675'}, ...
    {[0 4], [0 3], [1.6 3], [3.0 3], [-1.4 3], [-2.6 3], [0 1.6], [-1.4 1.6], [-2.6 1.6], ...
     [-1.4 0.4], [0 0.4], [1.3 1.6], [2.8 1.6]});
E = {'650', '632', '601, 2000 ft'; '632', '633', '602, 500 ft'; '633', '634', 'XFM-1'; ...
     '632', '645', '603, 500 ft'; '645', '646', '603, 300 ft'; '632', '671', '601, 2000 ft'; ...
     '671', '684', '604, 300 ft'; '684', '611', '605, 300 ft'; '684', '652', '607, 800 ft'; ...
     '671', '680', '601, 1000 ft'; '671', '692', 'switch'; '692', '675', '606, 500 ft'};
for k = 1:size(E, 1)
    a = P(E{k, 1});
    b = P(E{k, 2});
    plot(ax, [a(1) b(1)], [a(2) b(2)], '-', 'Color', [0.15 0.15 0.15], 'LineWidth', 2.2);
    m = (a + b) / 2;
    if a(2) == b(2)
        text(ax, m(1), m(2) + 0.15, E{k, 3}, 'FontSize', 9, 'HorizontalAlignment', 'center', 'Color', [0.35 0.35 0.35]);
    else
        text(ax, m(1) - 0.08, m(2), E{k, 3}, 'FontSize', 9, 'HorizontalAlignment', 'right', 'Color', [0.35 0.35 0.35]);
    end
end
plot(ax, [0 0], [4 4.55], 'k-', 'LineWidth', 2.2);
plot(ax, 0, 4.65, 'o', 'MarkerSize', 22, 'MarkerEdgeColor', 'k', 'LineWidth', 1.5);
text(ax, 0.25, 4.65, 'Substation source 4.16 kV (Src\_650)', 'FontSize', 10);
keys = P.keys;
for k = 1:numel(keys)
    q = P(keys{k});
    plot(ax, q(1), q(2), 'o', 'MarkerSize', 10, 'MarkerFaceColor', [0.2 0.45 0.8], 'MarkerEdgeColor', 'k');
    text(ax, q(1), q(2) - 0.22, keys{k}, 'FontWeight', 'bold', 'FontSize', 11, 'HorizontalAlignment', 'center');
end
% lateral breakers + meters
brk = {[0.45 3], 'Brk\_632\_633 + VI\_633L'; [1.85 1.6], 'Brk\_692\_675 + VI\_675L'};
for k = 1:2
    q = brk{k, 1};
    plot(ax, q(1), q(2), 's', 'MarkerSize', 14, 'MarkerFaceColor', [0.13 0.7 0.3], 'MarkerEdgeColor', 'k', 'LineWidth', 1.2);
    text(ax, q(1), q(2) - 0.42, brk{k, 2}, 'FontSize', 9, 'HorizontalAlignment', 'center', 'Color', [0.1 0.45 0.15]);
end
plot(ax, 0, 4.2, 'd', 'MarkerSize', 11, 'MarkerFaceColor', [0.95 0.75 0.1], 'MarkerEdgeColor', 'k');
text(ax, 0.15, 4.2, 'VI\_650 (feeder-head meter)', 'FontSize', 9);
% HIF injection points
for b = {'633', '675'}
    q = P(b{1});
    plot(ax, q(1), q(2) + 0.45, 'p', 'MarkerSize', 20, 'MarkerFaceColor', [0.95 0.4 0.1], 'MarkerEdgeColor', [0.6 0.1 0.05]);
    text(ax, q(1), q(2) + 0.8, sprintf('Emanuel HIF\nphases A/B/C'), 'FontSize', 9, 'HorizontalAlignment', 'center', 'Color', [0.7 0.2 0.05]);
end
% capacitor banks, step load
text(ax, 2.95, 1.25, 'Cap 675 (3\times200 kvar) + CapBrk\_675', 'FontSize', 8.5, 'Color', [0.2 0.3 0.6]);
text(ax, -3.1, 1.25, 'Cap 611C (100 kvar) + CapBrk\_611C', 'FontSize', 8.5, 'Color', [0.2 0.3 0.6]);
text(ax, 0.12, 1.25, 'LoadStepBrk\_671', 'FontSize', 8.5, 'Color', [0.2 0.3 0.6]);
title(ax, 'IEEE 13-node test feeder as modelled (protected laterals 632-633-634 and 692-675)', 'FontSize', 13);
xlim(ax, [-3.3 4.3]);
ylim(ax, [0 5]);
exportFig(fig, figDir, 'fig_oneline_ieee13.png');
end

%% ======================================================================
function N = step_architecture(~, figDir, N)
fig = lightFig([100 100 1400 800]);
ax = axes(fig, 'Position', [0 0 1 1], 'XLim', [0 140], 'YLim', [0 80]);
axis(ax, 'off');
hold(ax, 'on');
box = @(x, y, w, h, txt, col) drawBox(ax, x, y, w, h, txt, col);
arrow = @(p, q, txt) drawArrow(ax, p, q, txt);
blue = [0.86 0.92 1.0];
green = [0.88 0.97 0.88];
amber = [1.0 0.94 0.82];
grey = [0.94 0.94 0.94];
box(4, 52, 34, 20, {'PHYSICAL FEEDER', 'IEEE 13-node, 4.16 kV, unbalanced', 'Emanuel HIF branches @ 633 / 675', 'Lateral breakers Brk\_632\_633, Brk\_692\_675'}, blue);
box(4, 8, 34, 20, {'DIGITAL TWIN', 'Healthy replica, nominal loads', 'No fault branches', 'Mirrored lateral breakers'}, green);
box(45, 31, 21, 18, {'RESIDUAL', '\DeltaI = I_{phys} - I_{twin}', 'at I_{650}, I_{633L}, I_{675L}'}, grey);
box(72, 44, 28, 26, {'HIF RELAY (per lateral)', '2-cycle sliding window (667 samples)', 'db4 DWT, 5 levels: 87 features', 'Random Forest (100 trees, flattened)', '2-of-3 vote, latched trip'}, amber);
box(72, 8, 28, 22, {'OPERATOR PANEL', 'Control\_Mode: Auto / Manual', 'Manual\_Trip\_633, Manual\_Trip\_675:', 'Normal-Closed / Isolate-Trip'}, grey);
box(108, 28, 28, 22, {'BREAKER COMMAND', 'CloseCmd = 1 - trip', 'BrkCmd selector (Auto/Manual)', 'Lamps BrkLamp\_633 / 675'}, [0.95 0.88 0.95]);
arrow([38 62], [45 44], 'I_{phys}');
arrow([38 18], [45 36], 'I_{twin}');
arrow([66 40], [72 52], '\DeltaI');
arrow([100 57], [114 50], 'trip');
arrow([100 19], [114 28], 'mode, manual');
plot(ax, [122 122 21 21], [28 3 3 8], '-', 'Color', [0.5 0.1 0.5], 'LineWidth', 2);
plot(ax, [136 138 138 21 21], [39 39 77 77 72], '-', 'Color', [0.5 0.1 0.5], 'LineWidth', 2);
plot(ax, 21, 72, 'v', 'MarkerFaceColor', [0.5 0.1 0.5], 'MarkerEdgeColor', [0.5 0.1 0.5]);
plot(ax, 21, 8, '^', 'MarkerFaceColor', [0.5 0.1 0.5], 'MarkerEdgeColor', [0.5 0.1 0.5]);
text(ax, 70, 78.5, 'breaker command to feeder (closed loop)', 'Color', [0.5 0.1 0.5], 'FontSize', 10, 'HorizontalAlignment', 'center');
text(ax, 70, 1.3, 'same command mirrored into the twin (breaker-status synchronisation)', 'Color', [0.5 0.1 0.5], 'FontSize', 10, 'HorizontalAlignment', 'center');
text(ax, 55.5, 24, sprintf('single Simulink model, one powergui\ndiscrete solver, T_s = 50 \\mus'), 'FontSize', 9, 'HorizontalAlignment', 'center', 'Color', [0.3 0.3 0.3]);
exportFig(fig, figDir, 'fig_architecture.png');
end

function drawBox(ax, x, y, w, h, txt, col)
rectangle(ax, 'Position', [x y w h], 'Curvature', 0.08, 'FaceColor', col, 'EdgeColor', [0.25 0.25 0.25], 'LineWidth', 1.3);
text(ax, x + w / 2, y + h - 3.2, txt{1}, 'FontWeight', 'bold', 'FontSize', 11.5, 'HorizontalAlignment', 'center');
for k = 2:numel(txt)
    text(ax, x + w / 2, y + h - 3.2 - (k - 1) * 4, txt{k}, 'FontSize', 9.5, 'HorizontalAlignment', 'center');
end
end

function drawArrow(ax, p, q, txt)
annotation(ancestor(ax, 'figure'), 'arrow', p(1) / 140 * [1 0] + q(1) / 140 * [0 1], ...
    p(2) / 80 * [1 0] + q(2) / 80 * [0 1], 'LineWidth', 1.6, 'HeadWidth', 9);
text(ax, (p(1) + q(1)) / 2 - 1.5, (p(2) + q(2)) / 2 + 1.5, txt, 'FontSize', 10, 'HorizontalAlignment', 'right', 'FontWeight', 'bold');
end

%% ======================================================================
function N = step_arc(root, figDir, N)
% Standalone arc on an ideal 2.4 kV source (same bench as verify_emanuel_arc.m).
load_system(fullfile(root, 'models', 'emanuel_arc_subsystem.slx'));
cases = [1500 2000 200 300; 2400 2500 2000 2000];
fig = lightFig([100 100 1200 520]);
tl = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
ax1 = nexttile(tl);
hold(ax1, 'on');
ax2 = nexttile(tl);
hold(ax2, 'on');
cols = [0.1 0.35 0.8; 0.85 0.35 0.05];
for c = 1:2
    r = arcBench(cases(c, :));
    ss = r.t >= 0.05 & r.t < 0.05 + 2 / 60;
    vpp = linspace(-3500, 3500, 400);
    iIdeal = (vpp > cases(c, 1)) .* (vpp - cases(c, 1)) / cases(c, 3) + (vpp < -cases(c, 2)) .* (vpp + cases(c, 2)) / cases(c, 4);
    plot(ax1, r.v(ss) / 1e3, r.i(ss), '.', 'Color', cols(c, :), 'MarkerSize', 5, 'HandleVisibility', 'off');
    plot(ax1, vpp / 1e3, iIdeal, '-', 'Color', cols(c, :), 'LineWidth', 1.2, 'DisplayName', ...
        sprintf('V_p=%d, V_n=%d V, R_p=%d, R_n=%d \\Omega', cases(c, :)));
    plot(ax2, 1e3 * (r.t(ss) - 0.05), r.i(ss), '-', 'Color', cols(c, :), 'LineWidth', 1.3);
    N.arc.peak(c, :) = [max(r.i(ss)), min(r.i(ss))];
end
xlabel(ax1, 'Arc terminal voltage v (kV)');
ylabel(ax1, 'Arc current i (A)');
title(ax1, '(a) v-i characteristic: simulated (dots) vs Emanuel model (lines)');
legend(ax1, 'Location', 'northwest');
grid(ax1, 'on');
xlabel(ax2, 'Time (ms)');
ylabel(ax2, 'Arc current (A)');
title(ax2, '(b) Arc current, two cycles, ideal 2.4 kV RMS source');
legend(ax2, {'typical arc', 'weak (boundary) arc'}, 'Location', 'northeast');
grid(ax2, 'on');
exportFig(fig, figDir, 'fig_arc_characteristic.png');
end

function r = arcBench(p)
tb = 'arc_report_bench';
if bdIsLoaded(tb)
    close_system(tb, 0);
end
new_system(tb);
L = 'sps_lib';
load_system(L);
w = get_param(tb, 'ModelWorkspace');
assignin(w, 'Vp_arc', p(1)); assignin(w, 'Vn_arc', p(2));
assignin(w, 'Rp_arc', p(3)); assignin(w, 'Rn_arc', p(4));
add_block([L '/powergui'], [tb '/powergui']);
set_param([tb '/powergui'], 'SimulationMode', 'Discrete', 'SampleTime', '50e-6');
add_block([L '/Sources/AC Voltage Source'], [tb '/Vs'], 'Position', [60 120 100 160]);
set_param([tb '/Vs'], 'Amplitude', num2str(2400 * sqrt(2)), 'Frequency', '60');
add_block('emanuel_arc_subsystem/Emanuel_Arc_Fault', [tb '/Arc'], 'Position', [300 120 360 180]);
add_block([L '/Sensors and Measurements/Voltage Measurement'], [tb '/Vm'], 'Position', [200 220 230 250]);
for g = 1:3
    add_block([L '/Utilities/Ground'], sprintf('%s/G%d', tb, g), 'Position', [100 * g 320 100 * g + 30 340]);
end
ph = get_param([tb '/Vs'], 'PortHandles');
ports = [arrayfun(@(k) sprintf('Vs/LConn%d', k), 1:numel(ph.LConn), 'UniformOutput', false), ...
         arrayfun(@(k) sprintf('Vs/RConn%d', k), 1:numel(ph.RConn), 'UniformOutput', false)];
add_line(tb, ports{2}, 'G1/LConn1', 'autorouting', 'on');
add_line(tb, ports{1}, 'Arc/LConn1', 'autorouting', 'on');
add_line(tb, 'Arc/LConn2', 'G2/LConn1', 'autorouting', 'on');
add_line(tb, ports{1}, 'Vm/LConn1', 'autorouting', 'on');
add_line(tb, 'Vm/LConn2', 'G3/LConn1', 'autorouting', 'on');
q = get_param([tb '/Vm'], 'PortHandles');
set_param(q.Outport(1), 'DataLogging', 'on', 'DataLoggingNameMode', 'Custom', 'DataLoggingName', 'V_arc');
set_param(tb, 'StopTime', '0.1', 'SignalLogging', 'on');
out = sim(tb);
ia = out.logsout.get('I_arc').Values;
va = out.logsout.get('V_arc').Values;
r.t = ia.Time;
r.i = squeeze(ia.Data);
r.v = interp1(va.Time, squeeze(va.Data), r.t);
close_system(tb, 0);
end

%% ======================================================================
function N = step_proof(~, figDir, N)
r = run_twin_isolation_case('hif', 'Bus', '633', 'Phase', 'A');
tms = 1e3 * r.time;
fig = lightFig([100 100 1150 950]);
tl = tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tl, 'Three-tier closed-loop proof: typical HIF at Bus 633 phase A (fault at 100 ms)', 'FontSize', 12);
ax = nexttile(tl);
hold(ax, 'on');
plot(ax, tms, r.I_633_physical(:, 1), '-', 'Color', [0.8 0.15 0.1], 'LineWidth', 1.4, 'DisplayName', 'I_{633L,A} physical feeder');
plot(ax, tms, r.I_633_twin(:, 1), '--', 'Color', [0.1 0.3 0.8], 'LineWidth', 1.2, 'DisplayName', 'I_{633L,A} digital twin');
ylabel(ax, 'Current (A)');
title(ax, '(a) Physical vs twin lateral-head current, phase A', 'FontWeight', 'normal');
decorate(ax, r);
ax = nexttile(tl);
hold(ax, 'on');
pc = [0.8 0.15 0.1; 0.85 0.62 0; 0.1 0.35 0.8];
for p = 1:3
    plot(ax, tms, r.dI_633(:, p), 'Color', pc(p, :), 'LineWidth', 1.1, 'DisplayName', sprintf('\\DeltaI_{633L} phase %c', 'A' + p - 1));
end
plot(ax, tms, r.dI_675(:, 1), ':', 'Color', [0.45 0.45 0.45], 'LineWidth', 1, 'DisplayName', '\DeltaI_{675L} phase A');
ylabel(ax, '\DeltaI (A)');
title(ax, '(b) Residual current \DeltaI = I_{phys} - I_{twin}', 'FontWeight', 'normal');
decorate(ax, r);
ax = nexttile(tl);
hold(ax, 'on');
stairs(ax, tms, r.trip_633, 'Color', [0 0.45 0.74], 'LineWidth', 2, 'DisplayName', 'Relay 633 trip');
stairs(ax, tms, 0.97 * r.trip_675, 'Color', [0.62 0.2 0.7], 'LineWidth', 2, 'DisplayName', 'Relay 675 trip');
ylim(ax, [-0.1 1.2]);
ylabel(ax, 'Trip');
xlabel(ax, 'Time (ms)');
title(ax, '(c) Breaker trip commands', 'FontWeight', 'normal');
decorate(ax, r);
exportFig(fig, figDir, 'fig_proof_three_tier_633A.png');
N.proof633A.tripTime = r.tripTime633;
N.proof633A.peakResidual = max(abs(r.dI_633(:)));
N.proof633A.preRms = r.I633L_preRMS;
N.proof633A.endRms = r.I633L_endRMS;
end

function decorate(ax, r)
grid(ax, 'on');
xlim(ax, [60 200]);
xline(ax, 100, '--', 'fault', 'Color', [0.85 0.55 0], 'HandleVisibility', 'off', 'LabelVerticalAlignment', 'bottom');
if ~isnan(r.tripTime633)
    xline(ax, 1e3 * r.tripTime633, '--', 'trip', 'Color', [0.8 0.1 0.1], 'HandleVisibility', 'off', 'LabelVerticalAlignment', 'bottom');
end
legend(ax, 'Location', 'eastoutside');
end

%% ======================================================================
function N = step_run10s(~, figDir, N)
sys = 'ieee13_hif_twin_system';
stage_operator_demo('633A');
set_param(sys, 'EnablePacing', 'off');
t0 = tic;
o = sim(sys);
N.run10s.wall = toc(t0);
g = @(n) o.logsout.get(n).Values;
t = g('I_633L').Time;
I3 = squeeze(g('I_633L').Data);
I5 = squeeze(g('I_675L').Data);
tr = squeeze(g('Trip_633').Data);
N.run10s.trip633 = t(find(tr > 0.5, 1));
N.run10s.trip675any = any(squeeze(g('Trip_675').Data) > 0.5);
N.run10s.I633pre = max(rms(I3(t > 2.5 & t < 3, :)));
N.run10s.I633end = max(rms(I3(t > 9.5, :)));
N.run10s.I675end = max(rms(I5(t > 9.5, :)));
pc = [0.8 0.15 0.1; 0.85 0.62 0; 0.1 0.35 0.8];
fig = lightFig([100 100 1200 950]);
tl = tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tl, sprintf('Scope\\_Isolated\\_Current, 10 s staged run: HIF at Bus 633 phase A at t = 3.0 s, trip at %.4f s', N.run10s.trip633), 'FontSize', 12);
panes = {I3, 'Lateral 632-633 head current I_{633L} (A)', [0 10]; I5, 'Lateral 692-675 head current I_{675L} (A)', [0 10]; ...
         I3, 'Lateral 632-633, zoom on fault inception and isolation (A)', [2.95 3.1]};
for k = 1:3
    ax = nexttile(tl);
    hold(ax, 'on');
    for p = 1:3
        plot(ax, t, panes{k, 1}(:, p), 'Color', pc(p, :), 'LineWidth', 0.6 + 0.6 * (k == 3));
    end
    xlim(ax, panes{k, 3});
    grid(ax, 'on');
    title(ax, panes{k, 2}, 'FontWeight', 'normal');
    xline(ax, 3.0, '--', 'fault 3.0 s', 'Color', [0.85 0.55 0]);
    xline(ax, N.run10s.trip633, '--', 'trip', 'Color', [0.8 0.1 0.1], 'LabelHorizontalAlignment', 'left');
    ylabel(ax, 'A');
end
xlabel(ax, 'Time (s)');
legend(ax, {'phase A', 'phase B', 'phase C'}, 'Location', 'eastoutside');
exportFig(fig, figDir, 'fig_isolated_current_10s.png');
close_system(sys, 0);
end

%% ======================================================================
function N = step_scope(~, figDir, N)
% Scope_Isolated_Current signals of the 10 s staged Auto run (typical 633A
% arc at 3.0 s), in the scope's two-display layout on a white background:
% (a) the whole run, (b) 2.95-3.10 s around inception and isolation.
sys = 'ieee13_hif_twin_system';
stage_operator_demo('633A', 'StopTime', 10);
set_param(sys, 'EnablePacing', 'off');
closeScopes(sys);
o = sim(sys);
g = @(n) o.logsout.get(n).Values;
t = g('I_633L').Time;
tr = squeeze(g('Trip_633').Data);
I3 = squeeze(g('I_633L').Data);
I5 = squeeze(g('I_675L').Data);
N.scope.run1 = struct('stop', 10, 'trip633', t(find(tr > 0.5, 1)), ...
    'clear633', t(find(any(abs(I3) > 0.5, 2), 1, 'last')));
N.scope.run2 = N.scope.run1;
fig = lightFig([100 100 1500 820]);
tl = tiledlayout(fig, 2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
spans = {[0 10], '(a) full ten-second run'; [2.95 3.10], '(b) 2.95-3.10 s, inception and isolation'};
for c = 1:2
    scopeAxes(nexttile(tl, c), t, I3, spans{c, 1}, [-120 120], ...
        sprintf('%s: lateral 632-633 head current I_{633L}, phases A/B/C', spans{c, 2}), c == 1);
    scopeAxes(nexttile(tl, c + 2), t, I5, spans{c, 1}, [-300 300], ...
        'Lateral 692-675 head current I_{675L}, phases A/B/C', false);
    xlabel(nexttile(tl, c + 2), 'Time (s)');
end
exportFig(fig, figDir, 'fig_scope_isolated_current.png');
close_system(sys, 0);
end

function closeScopes(sys)
% No scope windows during batch runs (they redraw every sample).
for sc = {'Scope_Isolated_Current', 'Scope_Relays', 'Scope_Residuals'}
    set_param([sys '/' sc{1}], 'Open', 'off');
end
end

function scopeAxes(ax, t, I, xl, yl, ttl, withLegend)
% One scope display on a white background: black axes, dark red / green /
% blue phase traces (phase A / B / C).
pc = [0.80 0.08 0.08; 0.05 0.55 0.15; 0.05 0.25 0.80];
sel = t >= xl(1) - 1e-9 & t <= xl(2) + 1e-9;
hold(ax, 'on');
for p = 1:3
    plot(ax, t(sel), I(sel, p), 'Color', pc(p, :), 'LineWidth', 0.6 + 0.6 * (diff(xl) < 1));
end
set(ax, 'Color', 'w', 'XColor', 'k', 'YColor', 'k', 'GridColor', [0.6 0.6 0.6], 'Box', 'on', 'FontSize', 10);
grid(ax, 'on');
xlim(ax, xl);
ylim(ax, yl);
ylabel(ax, 'Current (A)');
title(ax, ttl, 'FontWeight', 'normal', 'FontSize', 10.5);
if withLegend
    legend(ax, {'phase A', 'phase B', 'phase C'}, 'Location', 'northeast', 'Orientation', 'horizontal');
end
end

%% ======================================================================
function N = step_manual(root, figDir, N)
sys = 'ieee13_hif_twin_system';
evalin('base', 'clear out');
stage_operator_demo('633A', 'Mode', 'Manual');
set_param(sys, 'EnablePacing', 'off');
closeScopes(sys);
acts = {4.0, 'Manual_Trip_633', '0'; 6.0, 'Manual_Trip_633', '1'; 7.0, 'Control_Mode', '1'};
done = false(1, 3);
at = nan(1, 3);
set_param(sys, 'SimulationCommand', 'start');
t0 = tic;
waitForStart(sys);
while ~strcmp(get_param(sys, 'SimulationStatus'), 'stopped') && toc(t0) < 900
    ts = get_param(sys, 'SimulationTime');
    for a = 1:3
        if ~done(a) && ts >= acts{a, 1}
            set_param([sys '/' acts{a, 2}], 'Value', acts{a, 3});
            done(a) = true;
            at(a) = ts;
        end
    end
    pause(0.05);
end
% Logged signals of the finished interactive run, from its Simulation Data
% Inspector run (the base-workspace 'out' of an interactive run is not
% always available to scripts).
run = Simulink.sdi.getCurrentSimulationRun(sys);
g = @(n) sdiValues(run, n);
t = g('I_633L').Time;
env = @(I) max(sqrt(movmean(squeeze(I).^2, [332 0], 1)), [], 2);
e3 = env(g('I_633L').Data);
e3t = env(g('twin_I_633L').Data);
e5 = env(g('I_675L').Data);
arc = abs(squeeze(g('I_arc_633A').Data));
tr = squeeze(g('Trip_633').Data);
N.manual.actTimes = at;
N.manual.trip633 = t(find(tr > 0.5, 1));
win = @(x, a, b) max(x(t > a & t < b));
N.manual.table = [win(e3, 3.3, at(1)), win(e5, 3.3, at(1)); win(e3, at(1) + 0.05, at(2)), win(e5, at(1) + 0.05, at(2)); ...
    win(e3, at(2) + 0.05, at(3)), win(e5, at(2) + 0.05, at(3)); win(e3, at(3) + 0.05, 10), win(e5, at(3) + 0.05, 10)];
% Dynamic response: residuals in each interval (1-cycle RMS, max phase) and
% the instants at which the lateral current stops / resumes after each action.
I3 = squeeze(g('I_633L').Data);
r3 = env(I3 - squeeze(g('twin_I_633L').Data));
try
    r5 = env(squeeze(g('I_675L').Data) - squeeze(g('twin_I_675L').Data));
catch
    r5 = nan(size(t));
end
live = any(abs(I3) > 0.5, 2);
seg = @(a, b) t > a & t < b;
lastOn = @(a, b) t(find(live & seg(a, b), 1, 'last'));
firstOn = @(a, b) t(find(live & seg(a, b), 1));
iv = [3.3, at(1); at(1) + 0.05, at(2); at(2) + 0.05, at(3); at(3) + 0.05, 10];
N.manual.dyn = struct('isolateClear', lastOn(at(1), at(2)), 'restoreFlow', firstOn(at(2), at(3)), ...
    'autoClear', lastOn(at(3), 10), ...
    'res633', arrayfun(@(k) win(r3, iv(k, 1), iv(k, 2)), 1:4), ...
    'res675', arrayfun(@(k) win(r5, iv(k, 1), iv(k, 2)), 1:4), ...
    'arc', arrayfun(@(k) win(env(arc), iv(k, 1), iv(k, 2)), 1:4));
mode = double(t >= at(3));
manualCmd = 1 - double(t >= at(1) & t < at(2));
fig = lightFig([100 100 1200 950]);
tl = tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tl, 'Operator supervisory control, 10 s run: Manual mode, manual isolate / restore, hand-back to Auto', 'FontSize', 12);
ax = nexttile(tl);
hold(ax, 'on');
stairs(ax, t, mode + 2.2, 'Color', [0.1 0.35 0.8], 'LineWidth', 2);
stairs(ax, t, manualCmd, 'Color', [0.85 0.4 0], 'LineWidth', 2);
stairs(ax, t, tr * 0.9 + 1.1, ':', 'Color', [0.6 0.1 0.1], 'LineWidth', 2);
yticks(ax, [0 1 1.1 2 2.2 3.2]);
yticklabels(ax, {'Isolate', 'Closed', 'relay 0', 'relay trip', 'Manual', 'Auto'});
ylim(ax, [-0.2 3.5]);
title(ax, '(a) Control\_Mode (blue), Manual\_Trip\_633 (orange), relay 633 latch (dotted)', 'FontWeight', 'normal');
markActs(ax, at);
ax = nexttile(tl);
hold(ax, 'on');
plot(ax, t, e3, 'Color', [0 0.45 0.74], 'LineWidth', 1.6, 'DisplayName', 'L633 physical');
plot(ax, t, e3t, '--', 'Color', [0.3 0.75 0.93], 'LineWidth', 1.2, 'DisplayName', 'L633 twin');
plot(ax, t, e5, 'Color', [0.62 0.2 0.7], 'LineWidth', 1.6, 'DisplayName', 'L675 physical');
ylabel(ax, 'RMS (A)');
title(ax, '(b) Lateral head currents (1-cycle RMS, max phase)', 'FontWeight', 'normal');
legend(ax, 'Location', 'east');
markActs(ax, at);
ax = nexttile(tl);
plot(ax, t, arc, 'Color', [0.85 0.33 0.1]);
ylabel(ax, '|i_{arc}| (A)');
xlabel(ax, 'Time (s)');
title(ax, '(c) Emanuel arc current at Bus 633 phase A', 'FontWeight', 'normal');
markActs(ax, at);
exportFig(fig, figDir, 'fig_operator_manual_override.png');
% Scope_Isolated_Current signals of the same run (two-display layout, white)
I5 = squeeze(g('I_675L').Data);
fig = lightFig([100 100 1500 640]);
tl = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
scopeAxes(nexttile(tl), t, I3, [0 10], [-120 120], 'Lateral 632-633 head current I_{633L}, phases A/B/C', true);
markActs(gca, at);
scopeAxes(nexttile(tl), t, I5, [0 10], [-300 300], 'Lateral 692-675 head current I_{675L}, phases A/B/C', false);
markActs(gca, at);
xlabel(gca, 'Time (s)');
exportFig(fig, figDir, 'fig_scope_manual_override.png');
close_system(sys, 0);
end

function markActs(ax, at)
grid(ax, 'on');
xlim(ax, [0 10]);
xline(ax, 3.0, '--', 'arc', 'Color', [0.85 0.55 0], 'HandleVisibility', 'off');
labels = {'Isolate', 'Restore', 'Auto'};
for a = 1:3
    xline(ax, at(a), ':', labels{a}, 'Color', [0.3 0.3 0.3], 'HandleVisibility', 'off');
end
end

%% ======================================================================
function N = step_wavelet(~, figDir, N)
r = run_twin_isolation_case('hif', 'Bus', '633', 'Phase', 'A');
W = 667;
iPre = find(r.time >= 0.0995 - (W - 1) * 50e-6, 1);
iPost = find(r.time >= 0.1005, 1);
segs = {r.dI_633(iPre:iPre + W - 1, 1), r.dI_633(iPost:iPost + W - 1, 1)};
names = {'pre-fault window', 'in-fault window'};
fig = lightFig([100 100 1200 1000]);
tl = tiledlayout(fig, 7, 2, 'TileSpacing', 'tight', 'Padding', 'compact');
title(tl, 'db4 five-level DWT of the lateral-633 residual (phase A), 2-cycle windows', 'FontSize', 12);
bands = {'signal', 'A5 (0-312 Hz)', 'D5 (312-625 Hz)', 'D4 (0.63-1.25 kHz)', 'D3 (1.25-2.5 kHz)', 'D2 (2.5-5 kHz)', 'D1 (5-10 kHz)'};
E = zeros(2, 6);
for s = 1:2
    x = segs{s};
    [C, L] = wavedec(x, 5, 'db4');
    rec = {x, wrcoef('a', C, L, 'db4', 5)};
    for lvl = 5:-1:1
        rec{end + 1} = wrcoef('d', C, L, 'db4', lvl); %#ok<AGROW>
    end
    E(s, :) = [sum(appcoef(C, L, 'db4', 5).^2), arrayfun(@(l) sum(detcoef(C, L, l).^2), 5:-1:1)];
    for b = 1:7
        ax = nexttile(tl, (b - 1) * 2 + s);
        plot(ax, (0:W - 1) * 0.05, rec{b}, 'Color', [0.1 0.3 0.7] * (s == 1) + [0.8 0.2 0.1] * (s == 2));
        grid(ax, 'on');
        ylabel(ax, bands{b}, 'FontSize', 8);
        if b == 1
            title(ax, names{s});
        end
        if b < 7
            ax.XTickLabel = [];
        else
            xlabel(ax, 'Time within window (ms)');
        end
    end
end
exportFig(fig, figDir, 'fig_wavelet_decomposition.png');
fig = lightFig([100 100 900 450]);
ax = axes(fig);
b = bar(ax, categorical({'A5', 'D5', 'D4', 'D3', 'D2', 'D1'}, {'A5', 'D5', 'D4', 'D3', 'D2', 'D1'}), E');
b(1).FaceColor = [0.1 0.3 0.7];
b(2).FaceColor = [0.8 0.2 0.1];
set(ax, 'YScale', 'log');
grid(ax, 'on');
ylabel(ax, 'Sub-band energy  \Sigma c^2  (A^2)');
legend(ax, names, 'Location', 'northeast');
title(ax, 'Sub-band energies of the lateral-633 residual, phase A, before vs during the arc');
exportFig(fig, figDir, 'fig_wavelet_energies.png');
N.wavelet.energies = E;
end

%% ======================================================================
function N = step_ml(root, figDir, N)
S = load(fullfile(root, 'models', 'trained_classifiers.mat'), 'mdlRF', 'scaler', 'results', 'classNames');
F = load(fullfile(root, 'data', 'features.mat'), 'X', 'y', 'runIdx', 'featureNames');
classNames = S.classNames;
isTest = ismember(F.runIdx, S.results.testRuns);
Xz = (F.X - S.scaler.mu) ./ S.scaler.sigma;
% confusion matrix on test runs
fig = lightFig([100 100 820 680]);
% display labels without underscores (the chart renders "_x" as a subscript)
cc = confusionchart(fig, S.results.RandomForest.ConfusionMatrix, strrep(cellstr(string(classNames)), '_', ' '), ...
    'RowSummary', 'row-normalized', 'ColumnSummary', 'column-normalized');
cc.Title = 'Random Forest relay classifier: held-out test runs (window level)';
exportFig(fig, figDir, 'fig_confusion_rf.png');
% error vs number of trees
train = ~isTest;
lossTest = loss(S.mdlRF, Xz(isTest, :), F.y(isTest), 'Mode', 'cumulative');
lossTrain = loss(S.mdlRF, Xz(train, :), F.y(train), 'Mode', 'cumulative');
try
    lossOob = oobLoss(S.mdlRF, 'Mode', 'cumulative');
catch
    lossOob = [];
end
fig = lightFig([100 100 900 480]);
ax = axes(fig);
hold(ax, 'on');
plot(ax, lossTrain, 'LineWidth', 1.6, 'DisplayName', 'training windows (in-sample)');
if ~isempty(lossOob)
    plot(ax, lossOob, 'LineWidth', 1.6, 'DisplayName', 'out-of-bag estimate');
end
plot(ax, lossTest, 'LineWidth', 1.6, 'DisplayName', 'held-out test runs');
grid(ax, 'on');
xlabel(ax, 'Number of trees in the ensemble');
ylabel(ax, 'Misclassification rate');
title(ax, 'Learning curve of the bagged ensemble (classification error vs ensemble size)');
legend(ax, 'Location', 'northeast');
exportFig(fig, figDir, 'fig_rf_error_vs_trees.png');
N.ml.lossTestFinal = lossTest(end);
N.ml.lossTrainFinal = lossTrain(end);
if ~isempty(lossOob)
    N.ml.lossOobFinal = lossOob(end);
end
% feature importance
imp = predictorImportance(S.mdlRF);
[v, o] = sort(imp, 'descend');
top = 20;
fig = lightFig([100 100 900 650]);
ax = axes(fig);
barh(ax, flipud(v(1:top)'), 'FaceColor', [0.2 0.45 0.75]);
ax.YTick = 1:top;
ax.YTickLabel = strrep(flipud(F.featureNames(o(1:top))'), '_', '\_');
grid(ax, 'on');
xlabel(ax, 'Predictor importance (mean decrease in node risk)');
title(ax, 'Top 20 of 87 DWT / statistical features (Random Forest)');
exportFig(fig, figDir, 'fig_feature_importance.png');
N.ml.topFeatures = F.featureNames(o(1:top));
N.ml.topImportance = v(1:top);
N.ml.results = S.results;
N.ml.nTrees = S.mdlRF.NumTrained;
end

%% ======================================================================
function N = step_delays(root, figDir, N)
T = readtable(fullfile(root, 'results', 'twin_isolation_results.csv'));
d = T.DetectionDelay_ms;
fig = lightFig([100 100 1000 480]);
ax = axes(fig);
hasTrip = ~isnan(d);
b = bar(ax, categorical(T.Scenario(hasTrip), T.Scenario(hasTrip)), d(hasTrip), 'FaceColor', [0.2 0.5 0.3]);
b.Labels = compose('%.0f ms', d(hasTrip));
ylabel(ax, 'Fault-to-trip time (ms)');
yline(ax, 1000 / 60, ':', '1 cycle', 'Color', [0.4 0.4 0.4]);
yline(ax, 3000 / 60, ':', '3 cycles', 'Color', [0.4 0.4 0.4]);
grid(ax, 'on');
title(ax, 'Closed-loop clearance time per HIF scenario (all on the correct lateral; no trip in the 4 non-fault scenarios)');
exportFig(fig, figDir, 'fig_trip_delays.png');
N.delays.table = T;
end

%% ======================================================================
function N = step_dataset(root, figDir, N)
F = load(fullfile(root, 'data', 'features.mat'), 'y', 'lateral', 'runSource');
cats = categories(F.y);
counts = zeros(numel(cats), 2);
for c = 1:numel(cats)
    counts(c, :) = [nnz(F.y == cats{c} & F.lateral == '633'), nnz(F.y == cats{c} & F.lateral == '675')];
end
fig = lightFig([100 100 900 450]);
ax = axes(fig);
b = bar(ax, categorical(strrep(cats, '_', ' '), strrep(cats, '_', ' ')), counts, 'stacked');
b(1).FaceColor = [0 0.45 0.74];
b(2).FaceColor = [0.62 0.2 0.7];
set(ax, 'YScale', 'log');
legend(ax, {'lateral 633 windows', 'lateral 675 windows'});
ylabel(ax, 'Number of 2-cycle windows (log scale)');
grid(ax, 'on');
title(ax, sprintf('Training windows by class: %d windows from 900 simulation runs', numel(F.y)));
exportFig(fig, figDir, 'fig_dataset_classes.png');
N.dataset.counts = counts;
N.dataset.classes = cats;
N.dataset.nWindows = numel(F.y);
N.dataset.nBoundaryWindows = nnz(F.runSource == 'boundary');
end

%% ======================================================================
function N = step_speed(root, figDir, N)
% per-decision cost
B = load(fullfile(root, 'models', 'hif_relay_model.mat'));
Fe = load(fullfile(root, 'data', 'features.mat'), 'X');
z = (Fe.X(100, :) - B.scaler.mu) ./ B.scaler.sigma;
flat = rf_flatten(B.relayModel);
predict(B.relayModel, z);
tic;
for k = 1:30
    predict(B.relayModel, z);
end
tPredict = toc / 30;
rf_predict_flat(flat, z);
tic;
for k = 1:300
    rf_predict_flat(flat, z);
end
tFlat = toc / 300;
w = randn(667, 3);
hif_window_features(w);
tic;
for k = 1:30
    hif_window_features(w);
end
tFeat = toc / 30;
% wall-clock per simulated second
sys = 'ieee13_hif_twin_system';
load_system(fullfile(root, 'models', [sys '.slx']));
cfg = {'normal', 'false'; 'normal', 'true'; 'accelerator', 'false'; 'accelerator', 'true'};
rate = zeros(size(cfg, 1), 1);
oldDir = cd(tempdir);
cleanup = onCleanup(@() cd(oldDir));
for c = 1:size(cfg, 1)
    mk = @(T) Simulink.SimulationInput(sys).setModelParameter('StopTime', T, 'SimulationMode', cfg{c, 1}) ...
        .setBlockParameter([sys '/HIF_Relay_633'], 'FastPredict', cfg{c, 2}) ...
        .setBlockParameter([sys '/HIF_Relay_675'], 'FastPredict', cfg{c, 2});
    sim(mk('0.02'));
    tic;
    sim(mk('0.02'));
    t0 = toc;
    tic;
    sim(mk('0.52'));
    t1 = toc;
    rate(c) = (t1 - t0) / 0.5;
end
N.speed = struct('tPredict', tPredict, 'tFlat', tFlat, 'tFeatures', tFeat, 'config', {cfg}, 'wallPerSimSecond', rate);
fig = lightFig([100 100 1150 450]);
tl = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
ax = nexttile(tl);
bar(ax, categorical({'predict() on ensemble', 'flattened trees', 'db4 features'}, ...
    {'predict() on ensemble', 'flattened trees', 'db4 features'}), 1e3 * [tPredict tFlat tFeat], 'FaceColor', [0.85 0.4 0.1]);
set(ax, 'YScale', 'log');
ylabel(ax, 'Time per relay decision (ms, log scale)');
grid(ax, 'on');
title(ax, '(a) Cost of one relay decision');
text(ax, 1:3, 1e3 * [tPredict tFlat tFeat] * 1.3, compose('%.2f ms', 1e3 * [tPredict tFlat tFeat]), 'HorizontalAlignment', 'center');
ax = nexttile(tl);
labels = {'Normal + predict()', 'Normal + flat', 'Accel. + predict()', 'Accel. + flat'};
bar(ax, categorical(labels, labels), rate, 'FaceColor', [0.2 0.45 0.75]);
ylabel(ax, 'Wall-clock seconds per simulated second');
yline(ax, 1, '--', 'real time', 'Color', [0.8 0.1 0.1]);
grid(ax, 'on');
title(ax, '(b) Closed-loop simulation speed (lower is faster)');
text(ax, 1:4, rate * 1.04 + 0.5, compose('%.1f', rate), 'HorizontalAlignment', 'center');
exportFig(fig, figDir, 'fig_speed_benchmark.png');
close_system(sys, 0);
end

%% ======================================================================
function N = step_dashboard(~, figDir, N)
r = run_final_review_demo('633A', 'Animate', false);
exportgraphics(gcf, fullfile(figDir, 'fig_control_center_633A.png'), 'Resolution', 150, 'BackgroundColor', 'current');
close all force;
r2 = run_final_review_demo('675C', 'Animate', false);
exportgraphics(gcf, fullfile(figDir, 'fig_control_center_675C.png'), 'Resolution', 150, 'BackgroundColor', 'current');
N.dashboard.s633A = r.summary;
N.dashboard.s675C = r2.summary;
end

%% ======================================================================
function N = step_live(~, figDir, N)
% Real-time Control Center (live_control_center.m) captured at the end of
% two interactive runs: (1) Auto mode, the relay isolates a typical 633A
% arc; (2) Manual mode, the operator isolates lateral 633 with
% Manual_Trip_633 while lateral 675 stays in service.
sys = 'ieee13_hif_twin_system';
tag = 'LiveHIFControlCenter';
runs = {'auto', {'633A', 'StopTime', 2, 'TFault', 1.0, 'Theme', 'light'}, {}; ...
        'manual', {'633A', 'Mode', 'Manual', 'StopTime', 4, 'TFault', 1.0, 'Theme', 'light'}, {2.0, 'Manual_Trip_633', '0'}};
for k = 1:size(runs, 1)
    if bdIsLoaded(sys)
        close_system(sys, 0);
    end
    t0 = tic;
    live_control_center(runs{k, 2}{:});
    waitForStart(sys);
    act = runs{k, 3};
    done = isempty(act);
    while ~strcmp(get_param(sys, 'SimulationStatus'), 'stopped') && toc(t0) < 900
        if ~done && get_param(sys, 'SimulationTime') >= act{1}
            set_param([sys '/' act{2}], 'Value', act{3});
            N.live.(runs{k, 1}).actAt = get_param(sys, 'SimulationTime');
            done = true;
        end
        pause(0.05);
    end
    pause(2.5);   % let the timer draw the final state
    fig = findall(0, 'Type', 'figure', 'Tag', tag);
    exportgraphics(fig(1), fullfile(figDir, sprintf('fig_live_control_center_%s.png', runs{k, 1})), ...
        'Resolution', 150, 'BackgroundColor', 'current');
    cards = findall(fig(1), 'Type', 'text', 'FontSize', 10.5);
    N.live.(runs{k, 1}).cards = flipud(get(cards, 'UserData'));
    N.live.(runs{k, 1}).wall = toc(t0);
    close(fig);
    close_system(sys, 0);
end
end

function v = sdiValues(run, name)
% timeseries of one logged signal of an SDI run (data as [N x channels]).
s = run.getSignalsByName(name);
v = s(1).Values;
d = squeeze(v.Data);
if size(d, 1) ~= numel(v.Time)
    d = d.';
end
v = timeseries(d, v.Time);
end

function addArea(parent, names, label, color, fs, extraTop)
% Outline a group of blocks with a labelled area annotation (in memory only,
% for the canvas prints; the model is closed without saving).
if nargin < 6
    extraTop = 0;
end
pos = zeros(0, 4);
for k = 1:numel(names)
    b = [parent '/' names{k}];
    if getSimulinkBlockHandle(b) > 0
        pos(end + 1, :) = get_param(b, 'Position'); %#ok<AGROW>
    end
end
if isempty(pos)
    return
end
lines = strsplit(label, newline);
m = round(0.6 * fs);
l = min(pos(:, 1)) - m;
t = min(pos(:, 2)) - m - round(1.35 * fs * numel(lines)) - extraTop;
r = max(max(pos(:, 3)) + m, l + round(0.78 * fs * max(cellfun(@numel, lines))));
b = max(pos(:, 4)) + m;
h = add_block('built-in/Area', [parent '/' strrep(label, '/', '//')]);
a = get_param(h, 'Object');
a.Position = [l t r b];
a.BackgroundColor = mat2str(color);
a.FontSize = fs;
a.FontWeight = 'bold';
end

function addNote(parent, txt, frac, fs)
% Text note placed at a fraction [x y] of the subsystem's block extent.
P = cell2mat(get_param(find_system(parent, 'SearchDepth', 1, 'Type', 'Block'), 'Position'));
P = P(2:end, :);                        % first entry is the subsystem itself
x0 = min(P(:, 1)); y0 = min(P(:, 2));
w = max(P(:, 3)) - x0; hgt = max(P(:, 4)) - y0;
a = Simulink.Annotation(parent, txt);
a.FontSize = fs;
a.FontWeight = 'bold';
a.BackgroundColor = '[1 1 0.85]';
a.HorizontalAlignment = 'left';
n = max(cellfun(@numel, strsplit(txt, newline)));
a.Position = round([x0 + frac(1) * w, y0 + frac(2) * hgt, x0 + frac(1) * w + 0.7 * fs * n, y0 + frac(2) * hgt + 3 * fs]);
end

function setupIsolationScope(sys, timeSpan, overrun)
% Display-only settings of Scope_Isolated_Current for a screenshot (in memory).
cfg = get_param([sys '/Scope_Isolated_Current'], 'ScopeConfiguration');
cfg.TimeSpan = num2str(timeSpan);
cfg.TimeSpanOverrunAction = overrun;
cfg.Position = [60 60 1300 820];
cfg.ActiveDisplay = 1;
cfg.Title = 'Lateral 632-633 head current I633L, phases A/B/C (A)';
cfg.ActiveDisplay = 2;
cfg.Title = 'Lateral 692-675 head current I675L, phases A/B/C (A)';
c = get_param([sys '/Scope_Relays'], 'ScopeConfiguration');
c.Visible = false;
open_system([sys '/Scope_Isolated_Current']);
end

function captureScope(root, outPng)
% Screenshot of the Scope_Isolated_Current window (capture_window.ps1).
drawnow;
pause(3);
ps = fullfile(root, 'scripts', 'capture_window.ps1');
[st, msg] = system(sprintf('powershell -NoProfile -ExecutionPolicy Bypass -File "%s" -TitleLike "Scope_Isolated_Current" -OutPng "%s"', ps, outPng));
fprintf('    %s', msg);
if st ~= 0
    error('generate_report_figures:Capture', 'scope capture failed: %s', msg);
end
end

function waitForStart(sys)
% 'SimulationCommand' 'start' returns before the status leaves 'stopped';
% wait until the run has actually begun before polling for its end.
t0 = tic;
while strcmp(get_param(sys, 'SimulationStatus'), 'stopped') && toc(t0) < 120
    pause(0.1);
end
end

%% ======================================================================
function fig = lightFig(pos)
fig = figure('Visible', 'off', 'Color', 'w', 'Position', pos);
try
    theme(fig, 'light');
catch
end
end

function exportFig(fig, figDir, name)
exportgraphics(fig, fullfile(figDir, name), 'Resolution', 200);
close(fig);
end
