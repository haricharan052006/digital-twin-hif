function stream_live_hif_dashboard(action, varargin)
%STREAM_LIVE_HIF_DASHBOARD  Real-time, DURING-simulation dashboard engine.
%
% Called by HIFStreamDashboardBlock.m (a MATLAB System block wired into
% models/ieee13_physical.slx by add_stream_dashboard_block.m) at a
% decimated ~5 ms cadence while the simulation is actually running.
%
% Actions:
%   stream_live_hif_dashboard('init')          - build/find the shared
%       dashboard figure (SAME Tag as update_live_hif_dashboard.m uses -
%       'HIF_LiveDashboard' - so both files cooperate on one window) in
%       its idle/ready state. Called once by launch_realtime_demo.m.
%   stream_live_hif_dashboard('reset')         - (re)draw the static
%       diagram and reset all per-run streaming state. Called by
%       HIFStreamDashboardBlock's setupImpl at the START of every
%       simulation run, so each Run starts the live view fresh.
%   stream_live_hif_dashboard('tick', t, I650) - called every ~5 ms of
%       simulation time with the current time and 3-phase substation
%       current sample. Computes the residual against the cached
%       digital-twin baseline, applies a fast amplitude threshold to
%       decide whether to raise a PROVISIONAL alarm, and appends one
%       point to the live residual strip-chart.
%
% WHY A THRESHOLD, NOT THE SVM, DRIVES THIS DURING-SIMULATION ALARM: the
% trained SVM (models/trained_classifiers.mat) classifies a FULL, FIXED
% 300 ms / 6001-sample 5-level db4 wavelet feature vector
% (extract_features.m) - there is no valid way to re-run that DWT on a
% partial, still-growing window and get features on the same scale the
% model was trained on, so the SVM itself cannot meaningfully "stream".
% Instead:
%   - THIS file drives immediate, genuinely real-time visual feedback
%     from a simple |residual| threshold, decimated to ~200 Hz (5 ms) -
%     fast enough to feel instantaneous, cheap enough to never slow the
%     solver down.
%   - update_live_hif_dashboard.m (unchanged - still attached as StopFcn
%     by launch_realtime_demo.m) performs the ACCURATE SVM-based
%     confirmation the moment the run completes, using the full-
%     resolution logged I_650 signal, and updates the SAME shared window
%     with the confirmed final verdict - which may correct a threshold-
%     triggered "TRANSIENT DETECTED" false alarm back to green (e.g. a
%     benign capacitor-switching inrush can also cross the fast
%     threshold; only the SVM, on the complete window, can actually tell
%     it apart from an HIF).
% This mirrors how real protection relays combine a fast instantaneous
% pickup element with a slower, more discriminating confirmation stage,
% rather than pretending one model does both jobs at both speeds.
%
% THRESHOLD CALIBRATION NOTE: THRESHOLD_A below (0.3 A) is a reasonable
% starting guess given CLAUDE.md's ~2 A RMS typical arc current and a
% near-zero healthy residual - it has NOT been empirically calibrated
% against the residual amplitude distribution in data/raw_residuals.mat.
% Worth tuning against that data if false/missed provisional alarms show
% up in practice; it only affects how early/eagerly the FAST path
% reacts, never the final SVM-confirmed verdict.
%
% Requires: data/twin_baseline.mat (written by launch_live_demo.m or
% launch_realtime_demo.m).

persistent S twinCache

switch action
    case 'init'
        fig = getOrCreateSharedFigure();
        twinCache = loadTwinCache(twinCache);
        S = freshState(fig, twinCache);
        drawnow;

    case 'reset'
        if isempty(S) || ~isvalid(S.fig)
            fig = getOrCreateSharedFigure();
        else
            fig = S.fig;
        end
        twinCache = loadTwinCache(twinCache);
        S = freshState(fig, twinCache);

    case 'tick'
        if isempty(S) || ~isvalid(S.fig)
            % Defensive: a tick arrived with no initialized state (e.g.
            % the dashboard window was closed mid-run) - reinitialize
            % silently rather than erroring and aborting the simulation.
            fig = getOrCreateSharedFigure();
            twinCache = loadTwinCache(twinCache);
            S = freshState(fig, twinCache);
        end
        doTick(varargin{1}, varargin{2});

    otherwise
        error('stream_live_hif_dashboard:UnknownAction', 'Unknown action "%s".', action);
end

%% -------------------------------------------------------------- nested
    function doTick(t, I650)
        I650 = I650(:)';
        iTwinAtT = interp1(S.tTwin, S.iTwin, t, 'linear', 'extrap');
        dI = I650 - iTwinAtT;

        appendResidualPoint(t, dI);

        if ~S.confirmed && t >= S.ARM_TIME
            magNow = sqrt(mean(dI.^2));
            S.recentRms = [S.recentRms(2:end), magNow];
            smoothedMag = mean(S.recentRms);
            if ~S.provisionalAlarm && smoothedMag > S.THRESHOLD_A
                raiseProvisionalAlarm();
            elseif S.provisionalAlarm && smoothedMag < 0.5 * S.THRESHOLD_A
                % Dropped back below threshold before the run ended and
                % before the SVM confirmed anything (e.g. a spurious
                % blip) - revert so a run that never truly faults doesn't
                % sit in "classifying..." forever.
                clearProvisionalAlarm();
            end
        end

        drawnow limitrate;
    end

    function appendResidualPoint(t, dI)
        n = S.nPoints + 1;
        if n > numel(S.tBuf)
            % Ran past the preallocated buffer (StopTime longer than
            % expected) - grow it rather than error mid-run.
            growBy = numel(S.tBuf);
            S.tBuf = [S.tBuf, nan(1, growBy)];
            S.dIBuf = [S.dIBuf; nan(growBy, 3)];
        end
        S.tBuf(n) = t;
        S.dIBuf(n, :) = dI;
        S.nPoints = n;

        for k = 1:3
            set(S.hResidual(k), 'XData', S.tBuf(1:n), 'YData', S.dIBuf(1:n, k));
        end
        if n == 1
            xlim(S.axResidual, [0, max(S.tBuf(n) * 2, 0.05)]);
        else
            xlim(S.axResidual, [0, S.tBuf(n)]);
        end
    end

    function raiseProvisionalAlarm()
        S.provisionalAlarm = true;
        setBanner(S, 'ALARM: TRANSIENT DETECTED AT BUS 671 | SPAN: 632-671 | Classifying...', ...
            [0.90 0.55 0.10], [0.15 0.08 0]);
        set(S.hFaultLine, 'Color', [0.85 0.10 0.10], 'LineStyle', '-', 'LineWidth', 4);
        set(S.hFaultLineLabel, 'Visible', 'on');
        set(S.hFaultBusRing, 'Visible', 'on');
        set(S.hFaultBusLabel, 'Visible', 'on');
        startPulse();
    end

    function clearProvisionalAlarm()
        S.provisionalAlarm = false;
        stopPulseNow();
        setBanner(S, 'STATUS: NORMAL OPERATION', [0.13 0.55 0.13], [1 1 1]);
        set(S.hFaultLine, 'Color', [0 0 0], 'LineStyle', '--', 'LineWidth', 1.5);
        set(S.hFaultLineLabel, 'Visible', 'off');
        set(S.hFaultBusRing, 'Visible', 'off');
        set(S.hFaultBusLabel, 'Visible', 'off');
    end

    function startPulse()
        stopPulseNow();
        colors = [0.85 0.10 0.10; 0.95 0.55 0.10];
        ringH = S.hFaultBusRing;
        tmr = timer('Name', 'HIF_StreamPulseTimer', 'ExecutionMode', 'fixedRate', ...
            'Period', 0.4, 'TimerFcn', @(~, ~) pulseTick(ringH, colors));
        S.pulseTimer = tmr;
        start(tmr);
    end

    function stopPulseNow()
        if isfield(S, 'pulseTimer') && ~isempty(S.pulseTimer) && isvalid(S.pulseTimer)
            stop(S.pulseTimer);
            delete(S.pulseTimer);
        end
        S.pulseTimer = [];
    end
end

%% ======================================================================
function pulseTick(ringHandle, colors)
persistent idx
if isempty(idx)
    idx = 1;
end
if ~isvalid(ringHandle)
    return;
end
idx = 3 - idx;
ringHandle.EdgeColor = colors(idx, :);
drawnow limitrate;
end

%% ======================================================================
function twinCache = loadTwinCache(twinCache)
if ~isempty(twinCache)
    return;
end
projectRoot = fileparts(fileparts(mfilename('fullpath')));
cacheFile = fullfile(projectRoot, 'data', 'twin_baseline.mat');
if ~isfile(cacheFile)
    error('stream_live_hif_dashboard:TwinCacheMissing', ...
        '%s not found. Run launch_realtime_demo.m (or launch_live_demo.m) first.', cacheFile);
end
C = load(cacheFile, 'tTwin', 'iTwin');
twinCache.tTwin = C.tTwin;
twinCache.iTwin = C.iTwin;
end

%% ======================================================================
function S = freshState(fig, twinCache)
ud = fig.UserData;

% Axes handles assigned FIRST, before anything that reads S.axBanner /
% S.axDiagram / S.axResidual (setBanner and drawStaticDiagram below both
% need them) - this ordering was the actual bug: they were previously
% assigned at the END of this function, after setBanner(S, ...) had
% already been called and failed on the not-yet-existing field.
S.axBanner   = ud.axBanner;
S.axDiagram  = ud.axDiagram;
S.axResidual = ud.axResidual;

cla(S.axBanner);
cla(S.axDiagram);
cla(S.axResidual);

S.fig = fig;
S.tTwin = twinCache.tTwin;
S.iTwin = twinCache.iTwin;
S.THRESHOLD_A = 0.3;     % Amperes - see file header calibration note
S.ARM_TIME = 0.051;      % s - matches the value requested for arming the fast detector
S.recentRms = zeros(1, 5);
S.confirmed = false;
S.provisionalAlarm = false;
S.pulseTimer = [];

N_PREALLOC = 2000;
S.tBuf = nan(1, N_PREALLOC);
S.dIBuf = nan(N_PREALLOC, 3);
S.nPoints = 0;

setBanner(S, 'STATUS: NORMAL OPERATION - waiting for a run', [0.13 0.55 0.13], [1 1 1]);
[S.hFaultLine, S.hFaultLineLabel, S.hFaultBusRing, S.hFaultBusLabel] = ...
    drawStaticDiagram(S.axDiagram);

phaseCol = [0.85 0.16 0.16; 0.13 0.47 0.79; 0.20 0.60 0.25];
phaseTagAll = {'A', 'B', 'C'};
hold(S.axResidual, 'on');
S.hResidual = gobjects(1, 3);
for k = 1:3
    S.hResidual(k) = plot(S.axResidual, nan, nan, '-', 'Color', phaseCol(k, :), ...
        'LineWidth', 1.2, 'DisplayName', sprintf('\\DeltaI_%s', phaseTagAll{k}));
end
hold(S.axResidual, 'off');
grid(S.axResidual, 'on');
box(S.axResidual, 'on');
xlabel(S.axResidual, 'Time (s)');
ylabel(S.axResidual, 'Residual current (A)');
title(S.axResidual, 'Live residual current \DeltaI(t)');
legend(S.axResidual, 'Location', 'northeast', 'NumColumns', 3, 'FontSize', 8);
xlim(S.axResidual, [0 0.30]);

drawnow;
end

%% ======================================================================
function setBanner(S, txt, bgColor, textColor)
cla(S.axBanner);
axis(S.axBanner, [0 1 0 1]);
axis(S.axBanner, 'off');
rectangle(S.axBanner, 'Position', [0 0 1 1], 'FaceColor', bgColor, 'EdgeColor', 'none');
text(S.axBanner, 0.5, 0.5, txt, 'Color', textColor, 'FontSize', 15, 'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle');
end

%% ======================================================================
function [hFaultLine, hFaultLineLabel, hFaultBusRing, hFaultBusLabel] = drawStaticDiagram(ax)
% Draws the fixed part of the IEEE 13-bus single-line diagram once per
% run (busbars, feeder lines, generator symbol) and returns the handles
% for the four elements that DO change live: the 632-671 span, its
% 'FAULT SPAN' label, the Bus 671 alarm ring, and its 'FAULT BUS 671'
% label - all created here already but hidden/neutral, so later ticks
% only need set()/Visible toggles, never a redraw.
%
% Geometry duplicated verbatim from update_live_hif_dashboard.m's
% busLayout()/lineLayout()/generatorSymbolXY() so both dashboards render
% pixel-identical diagrams on the shared window.
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

genXY = [5.0, 8.1];
bus650 = busXY('650');
plot(ax, [bus650(1) genXY(1)], [bus650(2) genXY(2)], 'k-', 'LineWidth', 1.5);
rectangle(ax, 'Position', [genXY(1) - 0.3, genXY(2) - 0.3, 0.6, 0.6], 'Curvature', 1, ...
    'FaceColor', 'w', 'EdgeColor', 'k', 'LineWidth', 1.5);
text(ax, genXY(1), genXY(2), 'G', 'HorizontalAlignment', 'center', ...
    'VerticalAlignment', 'middle', 'FontWeight', 'bold');
text(ax, genXY(1), genXY(2) + 0.45, 'SUBSTATION', 'HorizontalAlignment', 'center', 'FontSize', 8);

FAULT_EDGE = {'632', '671'};
hFaultLine = gobjects(1);
hFaultLineLabel = gobjects(1);
for i = 1:size(edges, 1)
    a = edges{i, 1};
    b = edges{i, 2};
    pa = busXY(a);
    pb = busXY(b);
    isFaultEdge = strcmp(a, FAULT_EDGE{1}) && strcmp(b, FAULT_EDGE{2});
    if isFaultEdge
        hFaultLine = plot(ax, [pa(1) pb(1)], [pa(2) pb(2)], 'k--', 'LineWidth', 1.5);
        midX = (pa(1) + pb(1)) / 2;
        midY = (pa(2) + pb(2)) / 2;
        hFaultLineLabel = text(ax, midX + 0.5, midY, 'FAULT SPAN', 'Color', [0.75 0 0], ...
            'FontWeight', 'bold', 'FontSize', 9, 'HorizontalAlignment', 'left', 'Visible', 'off');
    else
        plot(ax, [pa(1) pb(1)], [pa(2) pb(2)], 'k--', 'LineWidth', 1.5);
    end
end

FAULT_BUS = '671';
hFaultBusRing = gobjects(1);
hFaultBusLabel = gobjects(1);
for i = 1:numel(busNames)
    nm = busNames{i};
    p = busXY(nm);
    plot(ax, [p(1) - BUS_HALF_WIDTH, p(1) + BUS_HALF_WIDTH], [p(2), p(2)], 'k-', 'LineWidth', 4);
    text(ax, p(1), p(2) + LABEL_OFFSET, nm, 'HorizontalAlignment', 'center', ...
        'FontWeight', 'bold', 'FontSize', 9, 'Color', DARK_TEXT);

    if strcmp(nm, FAULT_BUS)
        hFaultBusRing = rectangle(ax, 'Position', [p(1) - 0.45, p(2) - 0.45, 0.9, 0.9], ...
            'Curvature', 1, 'EdgeColor', [0.85 0.10 0.10], 'LineWidth', 3, 'FaceColor', 'none', ...
            'Visible', 'off');
        hFaultBusLabel = text(ax, p(1), p(2) - 0.55, sprintf('FAULT BUS %s', nm), ...
            'HorizontalAlignment', 'center', 'FontWeight', 'bold', 'Color', [0.75 0 0], ...
            'FontSize', 8, 'Visible', 'off');
    end
end

hold(ax, 'off');
title(ax, 'IEEE 13-Bus Feeder - Live Fault Annunciation');
end

%% ======================================================================
function busXY = busLayout()
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
function edges = lineLayout()
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
function fig = getOrCreateSharedFigure()
% SAME Tag as update_live_hif_dashboard.m's getOrCreateDashboardFigure -
% both files find/reuse the identical window regardless of which one
% creates it first.
FIG_TAG = 'HIF_LiveDashboard';
figs = findobj('Type', 'figure', 'Tag', FIG_TAG);
if ~isempty(figs)
    fig = figs(1);
    figure(fig);
    return;
end

fig = figure('Tag', FIG_TAG, 'Name', 'IEEE 13-Bus HIF Live Dashboard', ...
    'NumberTitle', 'off', 'Color', 'w', 'Position', [80 80 1000 800], ...
    'CloseRequestFcn', @sharedDashboardCloseRequest);

ud.axBanner   = axes(fig, 'Position', [0.05 0.90 0.90 0.08], 'Visible', 'off');
ud.axDiagram  = axes(fig, 'Position', [0.05 0.32 0.90 0.55]);
ud.axResidual = axes(fig, 'Position', [0.08 0.06 0.87 0.20]);
ud.pulseTimer = [];
ud.busHandles = containers.Map();
fig.UserData = ud;
end

%% ======================================================================
function sharedDashboardCloseRequest(fig, ~)
% Stops/deletes BOTH possible pulse-timer names this shared window can
% carry - 'HIF_DashboardPulseTimer' (update_live_hif_dashboard.m's
% post-run pulse) and 'HIF_StreamPulseTimer' (this file's live pulse) -
% regardless of which file actually created the figure, since either
% file's 'init'/'reset' path can run first depending on workflow
% (launch_realtime_demo.m always creates it via this file first; the
% plain StopFcn-only workflow from launch_live_demo.m creates it via
% update_live_hif_dashboard.m instead).
for nm = ["HIF_DashboardPulseTimer", "HIF_StreamPulseTimer"]
    tmrs = timerfind('Name', char(nm));
    for i = 1:numel(tmrs)
        if isvalid(tmrs(i))
            stop(tmrs(i));
            delete(tmrs(i));
        end
    end
end
delete(fig);
end
