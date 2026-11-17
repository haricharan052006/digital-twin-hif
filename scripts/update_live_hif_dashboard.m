function update_live_hif_dashboard(mode)
%UPDATE_LIVE_HIF_DASHBOARD  Post-run HIF classification + dashboard update.
%
% Intended as a Simulink StopFcn callback on ieee13_physical.slx:
%   set_param('ieee13_physical', 'StopFcn', 'update_live_hif_dashboard;')
% (set by launch_live_demo.m, for the current MATLAB session only.)
%
% WHAT "REAL-TIME" ACTUALLY MEANS HERE: StopFcn fires ONCE, after the
% ENTIRE simulation run has finished - this is NOT a per-timestep live
% update during the run. The trained classifier needs a FULL acquired
% residual-current window (matching generate_dataset.m / extract_features.m's
% design - see also benchmark_latency.m's note on this same
% acquisition-window property), so "real time" here means "an automatic,
% near-instantaneous decision the moment a completed run's data becomes
% available" - not continuous streaming classification during simulation.
%
% Modes:
%   update_live_hif_dashboard()       (or 'run', the default) - reads the
%       just-completed run from the base workspace, classifies it, and
%       updates the dashboard. This is what the StopFcn callback invokes.
%   update_live_hif_dashboard('init') - draws the dashboard in its idle
%       "Ready / Waiting for Run" state, with no classification performed.
%       Called once by launch_live_demo.m before any simulation has run.
%
% Data source (checked in this order, matching whatever the base
% workspace has been left holding after however the user ran the model):
%   1. base workspace variable 'out'      (a Simulink.SimulationOutput,
%                                           e.g. from out = sim(...))
%   2. base workspace variable 'logsout'  (a Dataset, automatically
%                                           populated by Simulink when the
%                                           model is run via the toolbar
%                                           Run button with signal logging
%                                           enabled - the expected path
%                                           for this demo)
%
% Styling (finalized): busbars are always solid black ('k-', LineWidth 4)
% and connecting lines are always dashed black ('k--', LineWidth 1.5),
% regardless of classification - the ONLY visual deviation on a detected
% HIF is the one faulted line span (bold red, 'FAULT SPAN' label) and the
% one faulted bus (a red/orange pulsing ring overlay, 'FAULT BUS <name>'
% label). Kept deliberately simple: no separate "healthy" or "neutral"
% color states.
%
% Requires: Wavelet Toolbox, Statistics and Machine Learning Toolbox.
% Requires models/trained_classifiers.mat. Uses a digital-twin baseline
% cached by launch_live_demo.m if present (base workspace variables
% liveDemo_tTwin / liveDemo_iTwin), falling back to simulating
% ieee13_digital_twin.slx itself, once, if no usable cache is found.

if nargin < 1
    mode = 'run';
end

persistent mdlSVM scaler classNames T_STOP_EXPECTED
if isempty(mdlSVM)
    [mdlSVM, scaler, classNames, T_STOP_EXPECTED] = loadClassifier();
end

fig = getOrCreateDashboardFigure();

if strcmp(mode, 'init')
    renderIdleState(fig);
    return;
elseif ~strcmp(mode, 'run')
    error('update_live_hif_dashboard:UnknownMode', 'Unknown mode "%s".', mode);
end

try
    [tPhys, iPhysRaw] = fetchPhysicalRun();
catch ME
    renderErrorState(fig, sprintf('Could not read simulation output: %s', ME.message));
    return;
end

[tTwin, iTwinRaw] = getCachedTwinBaseline(T_STOP_EXPECTED);

runDuration  = tPhys(end) - tPhys(1);
twinDuration = tTwin(end) - tTwin(1);
if runDuration < 0.9 * twinDuration
    renderErrorState(fig, sprintf(['Run duration (%.3f s) is shorter than the expected ' ...
        '%.3f s analysis window - classification skipped.'], runDuration, twinDuration));
    return;
end

tGrid = tTwin;
iPhys = resampleOnto(tPhys, iPhysRaw, tGrid);
dI = iPhys - iTwinRaw;

featVec = extractFeatureVector(dI, 'db4', 5, ...
    {'A5', 'D5', 'D4', 'D3', 'D2', 'D1'}, {'Energy', 'Entropy', 'Std', 'MaxAbs'});
featZ = (featVec - scaler.mu) ./ scaler.sigma;

predLabel = predict(mdlSVM, featZ);
if iscell(predLabel)
    predLabel = predLabel{1};
end
predLabel = char(predLabel);

if ~ismember(predLabel, classNames)
    renderErrorState(fig, sprintf('Unexpected prediction label "%s".', predLabel));
    return;
end

renderClassificationResult(fig, tGrid, dI, predLabel);
end

%% ======================================================================
function [mdlSVM, scaler, classNames, T_STOP] = loadClassifier()
projectRoot = locateProjectRoot();
modelsFile = fullfile(projectRoot, 'models', 'trained_classifiers.mat');
if ~isfile(modelsFile)
    error('update_live_hif_dashboard:ModelsFileMissing', ...
        '%s not found. Run scripts/train_classifiers.m first.', modelsFile);
end
S = load(modelsFile, 'mdlSVM', 'scaler', 'classNames');
mdlSVM = S.mdlSVM;
scaler = S.scaler;
classNames = S.classNames;
T_STOP = 0.30;   % matches generate_dataset.m's training window
end

%% ======================================================================
function projectRoot = locateProjectRoot()
% This file lives in <projectRoot>/scripts/.
here = fileparts(mfilename('fullpath'));
projectRoot = fileparts(here);
end

%% ======================================================================
function [t, y] = fetchPhysicalRun()
% Reads the just-completed ieee13_physical run's I_650 signal from
% whatever the base workspace has - 'out' (Simulink.SimulationOutput) if
% present AND actually valid, else 'logsout' directly (the toolbar-Run-
% button path, which is the expected way this demo is actually driven).
%
% A bare exist('out','var') check is not enough: a base-workspace 'out'
% left over from something unrelated (or a stale one from
% run_live_hif_case.m's own assignin('base','out',out) on an earlier
% invocation) is not necessarily a Simulink.SimulationOutput with a
% populated logsout - blindly doing out.logsout on it throws
% "Unrecognized field name" rather than falling back cleanly. Checked
% with isa/isprop instead of just exist, so a stray/invalid 'out' falls
% through to the logsout path (or the clear error below) instead of
% crashing.
gotOut = logical(evalin('base', 'exist(''out'', ''var'')'));
if gotOut
    out = evalin('base', 'out');
    gotOut = isa(out, 'Simulink.SimulationOutput') && isprop(out, 'logsout') && ~isempty(out.logsout);
end

if gotOut
    ds = out.logsout;
elseif logical(evalin('base', 'exist(''logsout'', ''var'')'))
    ds = evalin('base', 'logsout');
else
    error('update_live_hif_dashboard:NoSimOutput', ...
        ['No valid ''out'' (a Simulink.SimulationOutput with logsout) or ''logsout'' variable ' ...
         'found in the base workspace. Run the model first.']);
end

[t, y] = getLoggedSignal(ds, 'I_650');
end

%% ======================================================================
function [t, y] = getLoggedSignal(ds, name)
% Robust Dataset-unwrapping (same approach as beautify_model_layout.m's
% getLoggedSignal): handles a name lookup coming back empty (falls back
% to index 1) or nested inside another Dataset (multiple logged signals
% sharing an identical custom name - I_650 itself is unique in this
% model, but the guard costs nothing and protects against future
% instrumentation changes, e.g. the known I_arc name collision across
% the three Emanuel_Arc_Fault* branches).
sig = ds.get(name);
if isempty(sig)
    sig = ds.get(1);
end
guard = 0;
while isa(sig, 'Simulink.SimulationData.Dataset') && guard < 10
    sig = sig.get(1);
    guard = guard + 1;
end
if guard >= 10
    error('update_live_hif_dashboard:SignalNestingTooDeep', ...
        'Logged signal "%s" is nested more than 10 Datasets deep.', name);
end
t = sig.Values.Time;
y = squeeze(sig.Values.Data);
if isvector(y)
    y = y(:);
end
end

%% ======================================================================
function [tTwin, iTwin] = getCachedTwinBaseline(T_STOP)
% Reuses launch_live_demo.m's pre-simulated, cached twin baseline
% (base-workspace variables liveDemo_tTwin / liveDemo_iTwin) if present
% and covering at least T_STOP seconds; otherwise simulates
% ieee13_digital_twin.slx itself, once, as a fallback (so this function
% works even if launch_live_demo.m was skipped) and caches the result
% into the base workspace for next time.
haveCache = evalin('base', ...
    'exist(''liveDemo_tTwin'', ''var'') && exist(''liveDemo_iTwin'', ''var'')');
if haveCache
    tTwin = evalin('base', 'liveDemo_tTwin');
    iTwin = evalin('base', 'liveDemo_iTwin');
    if tTwin(end) >= T_STOP * 0.99
        return;
    end
end

fprintf(['update_live_hif_dashboard: no usable cached twin baseline found - simulating ' ...
    'ieee13_digital_twin.slx once (one-time cost)...\n']);
[tTwin, iTwin] = simulateTwinBaseline(T_STOP);
assignin('base', 'liveDemo_tTwin', tTwin);
assignin('base', 'liveDemo_iTwin', iTwin);
end

%% ======================================================================
function [t, y] = simulateTwinBaseline(T_STOP)
in = Simulink.SimulationInput('ieee13_digital_twin');
in = in.setModelParameter('StopTime', num2str(T_STOP));
out = sim(in);
[t, y] = getLoggedSignal(out.logsout, 'I_650');
end

%% ======================================================================
function yq = resampleOnto(t, y, tGrid)
[tu, ia] = unique(t, 'last');
yq = interp1(tu, y(ia, :), tGrid, 'linear', 'extrap');
end

%% ======================================================================
function x = extractFeatureVector(dIrun, WAVELET, LEVEL, subbandTags, statTags)
% Identical to extract_features.m: builds one run's 75-element feature
% row (phase A/B/C x 6 sub-bands x 4 stats, then 3 cross-phase features),
% in the exact column order scaler.mu / scaler.sigma / mdlSVM expect.
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

%% ======================================================================
function fig = getOrCreateDashboardFigure()
FIG_TAG = 'HIF_LiveDashboard';
figs = findobj('Type', 'figure', 'Tag', FIG_TAG);
if ~isempty(figs)
    fig = figs(1);
    figure(fig);
    return;
end

fig = figure('Tag', FIG_TAG, 'Name', 'IEEE 13-Bus HIF Live Dashboard', ...
    'NumberTitle', 'off', 'Color', 'w', 'Position', [80 80 1000 800], ...
    'CloseRequestFcn', @dashboardCloseRequest);

ud.axBanner   = axes(fig, 'Position', [0.05 0.90 0.90 0.08], 'Visible', 'off');
ud.axDiagram  = axes(fig, 'Position', [0.05 0.32 0.90 0.55]);
ud.axResidual = axes(fig, 'Position', [0.08 0.06 0.87 0.20]);
ud.pulseTimer = [];
ud.busHandles = containers.Map();
fig.UserData = ud;
end

%% ======================================================================
function dashboardCloseRequest(fig, ~)
% Registered as the dashboard figure's CloseRequestFcn so a running pulse
% timer is always stopped/deleted before the figure closes - an orphaned
% running timer referencing a deleted graphics handle is a well-known
% MATLAB footgun this avoids. Also stops stream_live_hif_dashboard.m's
% pulse timer (a different Name) in case that file's live streaming is
% active on this SAME shared window (both files use the identical figure
% Tag, 'HIF_LiveDashboard', and either can be the one that ends up
% creating it depending on which launcher/workflow runs).
stopExistingPulse(fig);
streamTmrs = timerfind('Name', 'HIF_StreamPulseTimer');
for i = 1:numel(streamTmrs)
    if isvalid(streamTmrs(i))
        stop(streamTmrs(i));
        delete(streamTmrs(i));
    end
end
delete(fig);
end

%% ======================================================================
function stopExistingPulse(fig)
ud = fig.UserData;
if isfield(ud, 'pulseTimer') && ~isempty(ud.pulseTimer) && isvalid(ud.pulseTimer)
    stop(ud.pulseTimer);
    delete(ud.pulseTimer);
end
ud.pulseTimer = [];
fig.UserData = ud;
end

%% ======================================================================
function busXY = busLayout()
% Standard IEEE 13-bus single-line diagram coordinates, matching this
% project's OWN build_ieee13_network.m topology: Bus 650 at the top
% (substation, with a generator symbol above it), branching down to 632,
% then to 645-646 / 633-634 / 671, and from 671 to 680 / 692-675 /
% 684-611-652.
busXY = containers.Map();
busXY('650') = [5.0, 7.2];
busXY('632') = [5.0, 5.0];
busXY('645') = [3.0, 5.0];
busXY('646') = [1.5, 5.0];
busXY('633') = [7.0, 5.0];
busXY('634') = [8.5, 5.0];
busXY('671') = [5.0, 3.0];
busXY('680') = [5.0, 1.0];
busXY('684') = [3.0, 3.0];
busXY('611') = [1.5, 3.0];
busXY('652') = [2.5, 1.0];
busXY('692') = [7.0, 3.0];
busXY('675') = [8.5, 3.0];
end

%% ======================================================================
function genXY = generatorSymbolXY()
% Substation generator circle symbol, drawn above Bus 650 and connected
% to it with a short solid line.
genXY = [5.0, 8.1];
end

%% ======================================================================
function edges = lineLayout()
% [fromBus, toBus] pairs matching build_ieee13_network.m's lineSegs table
% (Line_650_632, Line_632_633, Line_632_645, Line_645_646, Line_632_671,
% Line_671_684, Line_684_611, Line_684_652, Line_671_680), the 671-692 tie
% + Line_692_675, and the 633-634 transformer.
edges = {
    '650', '632';
    '632', '633';
    '633', '634';
    '632', '645';
    '645', '646';
    '632', '671';
    '671', '680';
    '671', '692';
    '692', '675';
    '671', '684';
    '684', '611';
    '684', '652'};
end

%% ======================================================================
function renderIdleState(fig)
stopExistingPulse(fig);
ud = fig.UserData;

drawBanner(ud.axBanner, 'READY - press Run in Simulink to classify a new event', ...
    [0.85 0.85 0.85], [0.2 0.2 0.2]);
busHandles = drawDiagram(ud.axDiagram, [], []);

cla(ud.axResidual);
title(ud.axResidual, 'Residual current \DeltaI(t) - waiting for a run');
xlabel(ud.axResidual, 'Time (s)');
ylabel(ud.axResidual, 'Residual current (A)');
grid(ud.axResidual, 'on');

ud.busHandles = busHandles;
fig.UserData = ud;
drawnow;
end

%% ======================================================================
function renderErrorState(fig, msg)
stopExistingPulse(fig);
ud = fig.UserData;
drawBanner(ud.axBanner, sprintf('DASHBOARD ERROR: %s', msg), [0.95 0.75 0.2], [0.2 0.1 0]);
drawnow;
end

%% ======================================================================
function renderClassificationResult(fig, tGrid, dI, predLabel)
stopExistingPulse(fig);
ud = fig.UserData;

isFault = startsWith(predLabel, 'HIF_Phase_');
FAULT_BUS = '671';
FAULT_EDGE = {'632', '671'};

if isFault
    alarmClass = upper(predLabel);   % e.g. 'HIF_PHASE_B' (underscores kept, not spaced)
    bannerText = sprintf('ALARM: %s DETECTED | Location: Bus %s | Span: Line %s - %s', ...
        alarmClass, FAULT_BUS, FAULT_EDGE{1}, FAULT_EDGE{2});
    drawBanner(ud.axBanner, bannerText, [0.80 0.10 0.10], [1 1 1]);
    busHandles = drawDiagram(ud.axDiagram, FAULT_BUS, FAULT_EDGE);
    ud.busHandles = busHandles;
    fig.UserData = ud;
    startPulse(fig, busHandles([FAULT_BUS '_ring']));
else
    statusClass = upper(strrep(predLabel, '_', ' '));   % 'NORMAL' or 'SWITCHING TRANSIENT'
    bannerText = sprintf('STATUS: %s', statusClass);
    drawBanner(ud.axBanner, bannerText, [0.13 0.55 0.13], [1 1 1]);
    busHandles = drawDiagram(ud.axDiagram, [], []);
    ud.busHandles = busHandles;
    fig.UserData = ud;
end

phaseCol = [0.85 0.16 0.16; 0.13 0.47 0.79; 0.20 0.60 0.25];
phaseTagAll = {'A', 'B', 'C'};
cla(ud.axResidual);
hold(ud.axResidual, 'on');
for k = 1:3
    plot(ud.axResidual, tGrid, dI(:, k), '-', 'Color', phaseCol(k, :), ...
        'LineWidth', 1.2, 'DisplayName', sprintf('\\DeltaI_%s', phaseTagAll{k}));
end
hold(ud.axResidual, 'off');
grid(ud.axResidual, 'on');
box(ud.axResidual, 'on');
xlabel(ud.axResidual, 'Time (s)');
ylabel(ud.axResidual, 'Residual current (A)');
title(ud.axResidual, sprintf('Residual current \\DeltaI(t) - classified as: %s', ...
    strrep(predLabel, '_', ' ')));
legend(ud.axResidual, 'Location', 'northeast', 'NumColumns', 3, 'FontSize', 8);

drawnow;
end

%% ======================================================================
function drawBanner(ax, txt, bgColor, textColor)
cla(ax);
axis(ax, [0 1 0 1]);
axis(ax, 'off');
rectangle(ax, 'Position', [0 0 1 1], 'FaceColor', bgColor, 'EdgeColor', 'none');
text(ax, 0.5, 0.5, txt, 'Color', textColor, 'FontSize', 16, 'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle');
end

%% ======================================================================
function busHandles = drawDiagram(ax, faultBus, faultEdge)
% faultBus/faultEdge empty -> healthy state (all busbars green, all lines
% dashed black). Otherwise -> fault state: the one faultEdge in bold red
% labeled 'FAULT SPAN', the one faultBus given a solid red busbar core
% plus a pulsing outer ring labeled 'HIF ARCING NODE' (the ring's
% EdgeColor is toggled by a timer - see startPulse/pulseTick), everything
% else neutral grey (see file header for the rationale on that design
% choice - the brief only specifies the two extreme states).
%
% Buses are drawn as horizontal busbar segments (matching a real
% single-line diagram convention), not circular markers, with number
% labels placed ABOVE each busbar so they never overlap the busbar itself
% or a neighboring bus (rows are 2 units apart vertically, comfortably
% more than the label's offset).
cla(ax);
hold(ax, 'on');
axis(ax, 'equal');
axis(ax, 'off');

BUS_HALF_WIDTH = 0.3;
LABEL_OFFSET = 0.35;
DARK_TEXT = [0.05 0.05 0.05];

busXY = busLayout();
edges = lineLayout();
busNames = keys(busXY);

% Substation generator symbol above Bus 650, connected by a plain solid
% line (not a switchable feeder line, so it is never dashed/highlighted).
genXY = generatorSymbolXY();
bus650 = busXY('650');
plot(ax, [bus650(1) genXY(1)], [bus650(2) genXY(2)], 'k-', 'LineWidth', 1.5);
rectangle(ax, 'Position', [genXY(1) - 0.3, genXY(2) - 0.3, 0.6, 0.6], 'Curvature', 1, ...
    'FaceColor', 'w', 'EdgeColor', 'k', 'LineWidth', 1.5);
text(ax, genXY(1), genXY(2), 'G', 'HorizontalAlignment', 'center', ...
    'VerticalAlignment', 'middle', 'FontWeight', 'bold');
text(ax, genXY(1), genXY(2) + 0.45, 'SUBSTATION', 'HorizontalAlignment', 'center', 'FontSize', 8);

% Connecting lines: always dashed black, except the one fault span (if
% any), which is bold solid red. No intermediate "neutral" state - kept
% deliberately simple per the finalized styling brief.
for i = 1:size(edges, 1)
    a = edges{i, 1};
    b = edges{i, 2};
    pa = busXY(a);
    pb = busXY(b);
    isFaultEdge = ~isempty(faultEdge) && ...
        ((strcmp(a, faultEdge{1}) && strcmp(b, faultEdge{2})) || ...
         (strcmp(a, faultEdge{2}) && strcmp(b, faultEdge{1})));
    if isFaultEdge
        plot(ax, [pa(1) pb(1)], [pa(2) pb(2)], 'r-', 'LineWidth', 4);
        midX = (pa(1) + pb(1)) / 2;
        midY = (pa(2) + pb(2)) / 2;
        text(ax, midX + 0.5, midY, 'FAULT SPAN', 'Color', [0.75 0 0], ...
            'FontWeight', 'bold', 'FontSize', 9, 'HorizontalAlignment', 'left');
    else
        plot(ax, [pa(1) pb(1)], [pa(2) pb(2)], 'k--', 'LineWidth', 1.5);
    end
end

% Busbars: always solid black - the only deviation is the faulted bus,
% which additionally gets a distinct red/orange ring indicator (pulsing -
% see startPulse/pulseTick) layered on top, labeled 'FAULT BUS <name>'.
busHandles = containers.Map();
for i = 1:numel(busNames)
    nm = busNames{i};
    p = busXY(nm);
    hbar = plot(ax, [p(1) - BUS_HALF_WIDTH, p(1) + BUS_HALF_WIDTH], [p(2), p(2)], ...
        'k-', 'LineWidth', 4);
    text(ax, p(1), p(2) + LABEL_OFFSET, nm, 'HorizontalAlignment', 'center', ...
        'FontWeight', 'bold', 'FontSize', 9, 'Color', DARK_TEXT);
    busHandles(nm) = hbar;

    if strcmp(nm, faultBus)
        ringH = rectangle(ax, 'Position', [p(1) - 0.45, p(2) - 0.45, 0.9, 0.9], ...
            'Curvature', 1, 'EdgeColor', [0.85 0.10 0.10], 'LineWidth', 3, 'FaceColor', 'none');
        text(ax, p(1), p(2) - 0.55, sprintf('FAULT BUS %s', nm), 'HorizontalAlignment', 'center', ...
            'FontWeight', 'bold', 'Color', [0.75 0 0], 'FontSize', 8);
        busHandles([nm '_ring']) = ringH;
    end
end

hold(ax, 'off');
title(ax, 'IEEE 13-Bus Feeder - Live Fault Annunciation');
end

%% ======================================================================
function startPulse(fig, ringHandle)
PULSE_COLORS = [0.85 0.10 0.10; 0.95 0.55 0.10];   % red <-> orange
t = timer('Name', 'HIF_DashboardPulseTimer', 'ExecutionMode', 'fixedRate', ...
    'Period', 0.5, 'TimerFcn', @(~, ~) pulseTick(ringHandle, PULSE_COLORS));
ud = fig.UserData;
ud.pulseTimer = t;
fig.UserData = ud;
start(t);
end

%% ======================================================================
function pulseTick(ringHandle, colors)
% ringHandle is the pulsing OUTER RING rectangle (see drawDiagram) - the
% solid red busbar CORE underneath it is drawn once and does not pulse.
persistent idx
if isempty(idx)
    idx = 1;
end
if ~isvalid(ringHandle)
    return;
end
idx = 3 - idx;   % toggles 1 <-> 2
ringHandle.EdgeColor = colors(idx, :);
drawnow limitrate;
end
