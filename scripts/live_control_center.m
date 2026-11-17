function live_control_center(scenario, varargin)
%LIVE_CONTROL_CENTER  Live Control Center for ieee13_hif_twin_system.slx:
% the Figure 4.9 layout (feeder topology mimic, status cards, four
% telemetry panes) updated WHILE the closed-loop digital twin simulates.
%
%   live_control_center('633A', 'Mode', 'Manual')  % stage, open and run
%   live_control_center('633A')                    % Auto mode (relay trips)
%   live_control_center('675C')                    % weak / boundary arc
%
% Name-value options (passed on to stage_operator_demo.m):
%   'StopTime' (10), 'TFault' (3.0), 'Mode' ('Auto' | 'Manual'),
%   'ManualTrip633' / 'ManualTrip675' ('Closed' | 'Trip'), 'PacingRate' (1),
%   'SimulationMode' ('accelerator' | 'normal')
% and:
%   'AutoStart'   true = start the simulation now (default); false = press
%                 Run in the Simulink toolbar yourself
%   'Window'      span of the two scrolling waveform panes, s (0.25)
%   'PollPeriod'  wall-clock seconds between updates (0.5)
%   'Scopes'      true = also keep the Simulink scopes open (default false:
%                 they redraw every 50 us sample and slow the run several-
%                 fold; the Control Center shows the same signals)
%   'Theme'       'dark' (default, control-room style) | 'light' (white
%                 background with dark lines and text, for printed reports)
%
% During the run, flip Control_Mode / Manual_Trip_633 / Manual_Trip_675 on
% the Simulink canvas: the mimic breakers (green CLOSED / red OPEN), the
% system-state text and the branch loads follow the breaker commands the
% feeder and twin actually receive (BrkCmd_633 / BrkCmd_675). Pressing Run
% again restarts the live view; closing the Control Center stops it.
%
% How it works: stage_operator_demo stages the model IN MEMORY. This
% function additionally (in memory only) logs the outputs of BrkCmd_633,
% BrkCmd_675 and Control_Mode and closes the Simulink scopes. A MATLAB
% timer then reads the signals the model already logs - feeder currents
% I_650 / I_633L / I_675L, residuals dI_633L / dI_675L, relay trips and
% classes - plus those three, from the running simulation's Simulation
% Data Inspector run, and redraws the figure. No block, callback or
% listener is added to the model; nothing runs inside the solver loop.
% Discard the staging afterwards with close_system('ieee13_hif_twin_system', 0).
%
% Speed: the closed-loop model (two EMT feeders at 20 kHz plus two relays)
% computes slower than real time on a laptop - about 6-7 wall-clock
% seconds per simulated second in Accelerator mode, more in Normal mode -
% and Simulation Pacing can only cap the speed, never raise it. The
% display therefore follows simulation time, a few updates per second.

TAG = 'LiveHIFControlCenter';
if nargin < 1
    scenario = '633A';
end
p = inputParser;
p.addParameter('StopTime', 10);
p.addParameter('TFault', 3.0);
p.addParameter('Mode', 'Auto');
p.addParameter('ManualTrip633', 'Closed');
p.addParameter('ManualTrip675', 'Closed');
p.addParameter('PacingRate', 1);
p.addParameter('SimulationMode', 'accelerator');
p.addParameter('AutoStart', true);
p.addParameter('Window', 0.25);
p.addParameter('PollPeriod', 0.5);
p.addParameter('Scopes', false);
p.addParameter('Theme', 'dark');
p.parse(varargin{:});
o = p.Results;

sys = 'ieee13_hif_twin_system';
latName = containers.Map({'633', '675'}, {'Lateral 632-633', 'Lateral 692-675'});
classNames = {'Normal', 'Switching transient', 'HIF phase A', 'HIF phase B', 'HIF phase C'};
SIGNALS = {'I_650', 'I_633L', 'I_675L', 'dI_633L', 'dI_675L', 'Trip_633', 'Trip_675', ...
    'Class_633', 'Class_675', 'Live_BrkCmd_633', 'Live_BrkCmd_675', 'Live_Control_Mode'};

% ---------------------------------------------------------------- scenario
key = upper(char(string(scenario)));
tok = regexp(key, '^(633|675)([ABC])$', 'tokens', 'once');
isHif = ~isempty(tok);
bus = '';
phase = '';
if isHif
    bus = tok{1};
    phase = tok{2};
    eventLat = bus;
    if strcmp(key, '675C')
        desc = sprintf('Weak/boundary HIF at Bus %s phase %s (Vp 2400 V, Vn 2500 V, Rp 2000, Rn 2000 Ohm) from t = %g s', ...
            bus, phase, o.TFault);
    else
        desc = sprintf('Typical HIF at Bus %s phase %s (Vp 1500 V, Vn 2000 V, Rp 200, Rn 300 Ohm) from t = %g s', ...
            bus, phase, o.TFault);
    end
elseif strcmp(key, 'CAP675')
    eventLat = '675';
    desc = sprintf('Capacitor bank 675 switched out at t = %g s (benign transient)', o.TFault);
elseif strcmp(key, 'HEALTHY')
    eventLat = '633';
    desc = 'Healthy feeder (no event)';
else
    error('live_control_center:BadScenario', 'Scenario must be ''633A''..''675C'', ''cap675'' or ''healthy''.');
end
otherLat = char(setdiff({'633', '675'}, eventLat));
evtIdx = 1 + strcmp(eventLat, '675');
othIdx = 3 - evtIdx;

% ------------------------------------------------------ live state
runId = NaN;
sig = struct();
running = false;
nDone = 0;           % samples already folded into the decimated history
H = struct('t', zeros(0, 1), 'env', zeros(0, 2), 'trip', zeros(0, 2), 'brk', zeros(0, 2));
lim = [1 1 200];
tIso = NaN;
isoBy = '';
tripSeen = [false false];
markers = gobjects(0);
mimicKey = '';
stats = struct('n', 0, 'tPoll', 0, 'tMax', 0, 'last', 0, 'wall', tic, 'lastEnd', tic);
warned = false;
stopTime = o.StopTime;

% ------------------------------------------------------------- staging
if bdIsLoaded(sys) && ~strcmp(get_param(sys, 'SimulationStatus'), 'stopped')
    error('live_control_center:Busy', 'Stop the running simulation of %s first.', sys);
end
stage_operator_demo(key, 'StopTime', o.StopTime, 'TFault', o.TFault, 'Mode', o.Mode, ...
    'ManualTrip633', o.ManualTrip633, 'ManualTrip675', o.ManualTrip675, ...
    'PacingRate', o.PacingRate, 'SimulationMode', o.SimulationMode);
if ~o.Scopes
    for s = {'Scope_Isolated_Current', 'Scope_Relays', 'Scope_Residuals'}
        set_param([sys '/' s{1}], 'Open', 'off');
    end
end
for b = {'BrkCmd_633', 'BrkCmd_675', 'Control_Mode'}
    ph = get_param([sys '/' b{1}], 'PortHandles');
    set_param(ph.Outport(1), 'DataLogging', 'on', 'DataLoggingNameMode', 'Custom', ...
        'DataLoggingName', ['Live_' b{1}]);
end

% -------------------------------------------------------------- figure
old = findall(0, 'Type', 'figure', 'Tag', TAG);
for f = old(:)'
    close(f);
end
C = palette(o.Theme);
fig = figure('Name', ['LIVE HIF Digital-Twin Control Center - ' key], 'NumberTitle', 'off', ...
    'Tag', TAG, 'Color', C.bg, 'Position', [60 60 1600 900], 'MenuBar', 'none', 'ToolBar', 'none', ...
    'CloseRequestFcn', @onClose);
try
    theme(fig, C.theme);   % keep MATLAB's own defaults (e.g. tick labels) consistent with the palette
catch
end
% Full-figure overlay axes (created first, so it stays underneath) holding
% the header and the status cards as plain text objects.
axT = axes(fig, 'Position', [0 0 1 1], 'Visible', 'off', 'XLim', [0 1], 'YLim', [0 1], ...
    'HitTest', 'off', 'PickableParts', 'none');
hold(axT, 'on');
txt = @(x, y, s, col, sz, varargin) text(axT, x, y, s, 'Color', col, 'FontSize', sz, ...
    'Interpreter', 'none', 'VerticalAlignment', 'middle', varargin{:});
txt(0.015, 0.962, 'IEEE 13-Node Feeder  |  Digital-Twin HIF Protection Control Center', C.text, 17, 'FontWeight', 'bold');
txt(0.015, 0.922, desc, C.muted, 11);
hdrLive = txt(0.985, 0.968, 'WAITING FOR RUN', C.amber, 12, 'FontWeight', 'bold', 'HorizontalAlignment', 'right');
hdrMode = txt(0.985, 0.934, 'MODE: -', C.text, 11, 'FontWeight', 'bold', 'HorizontalAlignment', 'right');

cardTitles = {'SYSTEM STATE', 'FAULTED BUS & LATERAL', 'EVENT CLASSIFICATION', ...
    'CLEARANCE SPEED', 'ADJACENT LATERAL SECURITY', 'BRANCH LOAD (live, 1-cycle RMS)'};
cardPos = [0.02 0.255; 0.22 0.255; 0.02 0.14; 0.22 0.14; 0.02 0.025; 0.22 0.025];
cards = gobjects(numel(cardTitles), 1);
for c = 1:numel(cardTitles)
    x = cardPos(c, 1);
    y = cardPos(c, 2);
    rectangle(axT, 'Position', [x y 0.195 0.105], 'FaceColor', C.card, 'EdgeColor', C.grid, 'LineWidth', 1);
    txt(x + 0.008, y + 0.082, cardTitles{c}, C.muted, 8.5, 'FontWeight', 'bold');
    cards(c) = txt(x + 0.008, y + 0.037, '-', C.text, 10.5, 'FontWeight', 'bold');
end
setText(cards(1), 'Waiting for simulation start', C.muted);

axM = axes(fig, 'Position', [0.02 0.40 0.40 0.45], 'Color', C.panel, 'XColor', 'none', ...
    'YColor', 'none', 'XLim', [-2.9 2.9], 'YLim', [0.0 4.75]);
hold(axM, 'on');
title(axM, 'Feeder Topology Mimic', 'Color', C.text, 'FontSize', 12);
M = drawMimic(axM, C);
[ax, Ln] = drawPanes();

% -------------------------------------------------------------- timer
delete(timerfindall('Tag', TAG));
tmr = timer('Tag', TAG, 'ExecutionMode', 'fixedSpacing', 'Period', o.PollPeriod, ...
    'BusyMode', 'drop', 'TimerFcn', @(~, ~) poll());
start(tmr);

fprintf('Live Control Center open: %s mode, fault at %g s, %g s run (%s).\n', ...
    o.Mode, o.TFault, o.StopTime, o.SimulationMode);
fprintf('Flip Control_Mode / Manual_Trip_633 / Manual_Trip_675 on the Simulink canvas during the run.\n');
fprintf('Afterwards discard the staging: close_system(''%s'', 0)\n', sys);
if o.AutoStart
    set_param(sys, 'SimulationCommand', 'start');
else
    fprintf('Press Run (Ctrl+T) in the Simulink toolbar to start.\n');
end

    % ==================================================================
    function onClose(~, ~)
        stop(tmr);
        delete(tmr);
        delete(fig);
    end

    % ==================================================================
    function poll()
        % Timer callback: read the running simulation's logged signals and
        % redraw. Skips a tick when the previous update was expensive, so
        % updates never take more than about 40 % of the wall-clock time.
        if ~ishghandle(fig)
            return;
        end
        if ~bdIsLoaded(sys)
            setText(hdrLive, 'MODEL CLOSED', C.muted);
            stop(tmr);
            return;
        end
        status = get_param(sys, 'SimulationStatus');
        if any(strcmp(status, {'running', 'paused'}))
            if toc(stats.lastEnd) < 1.5 * stats.last
                return;
            end
            running = true;
            update(false);
        elseif running && strcmp(status, 'stopped')
            running = false;
            update(true);
        elseif any(strcmp(status, {'initializing', 'updating', 'compiled'}))
            setText(hdrLive, 'COMPILING / STARTING ...', C.amber);
        end
    end

    % ==================================================================
    function update(final)
        tPoll = tic;
        try
            run = Simulink.sdi.getCurrentSimulationRun(sys);
            if isempty(run)
                return;
            end
            if run.ID ~= runId
                newRun(run);
            end
            % logged data so far (all signals at the 50 us base rate)
            V = struct();
            nAll = inf;
            for q = 1:numel(SIGNALS)
                if isempty(sig.(SIGNALS{q}))
                    s1 = run.getSignalsByName(SIGNALS{q});
                    if isempty(s1)
                        return;   % not streamed yet
                    end
                    sig.(SIGNALS{q}) = s1(1);
                end
                ts = sig.(SIGNALS{q}).Values;
                d = squeeze(ts.Data);
                if size(d, 1) ~= numel(ts.Time)
                    d = d.';
                end
                V.(SIGNALS{q}) = d;
                if q == 1
                    V.t = ts.Time;
                end
                nAll = min(nAll, numel(ts.Time));
            end
            if nAll < 2
                return;
            end
            t = V.t(nAll);
            dt = V.t(2) - V.t(1);
            m = max(1, round((1 / 60) / dt));
            brk = [V.Live_BrkCmd_633(1:nAll), V.Live_BrkCmd_675(1:nAll)];
            trip = [V.Trip_633(1:nAll), V.Trip_675(1:nAll)];
            mode = V.Live_Control_Mode(1:nAll);

            % fold new samples into the decimated history (every 10th sample)
            if nAll > nDone
                lo = max(1, nDone + 1 - m);
                e3 = max(sqrt(movmean(V.I_633L(lo:nAll, :) .^ 2, [m - 1, 0], 1)), [], 2);
                e5 = max(sqrt(movmean(V.I_675L(lo:nAll, :) .^ 2, [m - 1, 0], 1)), [], 2);
                idx = (nDone + 1):nAll;
                keep = idx(mod(idx - 1, 10) == 0 | idx == nAll);
                rel = keep - lo + 1;
                if ~isempty(H.t) && H.t(end) >= V.t(keep(1))
                    H = trimHistory(H, V.t(keep(1)));
                end
                H.t = [H.t; V.t(keep)];
                H.env = [H.env; e3(rel), e5(rel)];
                H.trip = [H.trip; trip(keep, :)];
                H.brk = [H.brk; brk(keep, :)];
                % events in the new samples
                for q = 1:2
                    if ~tripSeen(q)
                        j = find(trip(idx, q) > 0.5, 1);
                        if ~isempty(j)
                            tripSeen(q) = true;
                            for a = 3:4
                                markers(end + 1) = xline(ax(a), V.t(idx(j)), '--', 'Color', C.red, 'LineWidth', 1); %#ok<AGROW>
                            end
                        end
                    end
                end
                if isHif && isnan(tIso)
                    j = find(V.t(idx) >= o.TFault & brk(idx, evtIdx) < 0.5, 1);
                    if ~isempty(j)
                        tIso = V.t(idx(j));
                        if mode(idx(j)) > 0.5
                            isoBy = 'relay (Auto)';
                        else
                            isoBy = 'operator (Manual)';
                        end
                    end
                end
                nDone = nAll;
            end

            % panes 1-2: last o.Window seconds on a fixed "time before now" axis
            w = find(V.t(1:nAll) >= t - o.Window, 1):4:nAll;
            tr = V.t(w) - t;
            if strcmp(eventLat, '633')
                dE = V.dI_633L(w, :);
                dO = V.dI_675L(w, :);
            else
                dE = V.dI_675L(w, :);
                dO = V.dI_633L(w, :);
            end
            for q = 1:3
                set(Ln.i650(q), 'XData', tr, 'YData', V.I_650(w, q));
                set(Ln.res(q), 'XData', tr, 'YData', dE(:, q));
                set(Ln.oth(q), 'XData', tr, 'YData', dO(:, q));
            end
            growLim(1, max(abs(V.I_650(w, :)), [], 'all'), [-1 1]);
            growLim(2, max(abs([dE(:); dO(:)])), [-1 1]);
            setText(Ln.now, sprintf('t = %.2f s', t), C.muted);

            % panes 3-4: whole run so far (decimated history)
            set(Ln.trip(1), 'XData', H.t, 'YData', H.trip(:, 1));
            set(Ln.trip(2), 'XData', H.t, 'YData', 0.97 * H.trip(:, 2));
            set(Ln.brk(1), 'XData', H.t, 'YData', 0.92 * (1 - H.brk(:, 1)));
            set(Ln.brk(2), 'XData', H.t, 'YData', 0.88 * (1 - H.brk(:, 2)));
            set(Ln.env(1), 'XData', H.t, 'YData', H.env(:, 1));
            set(Ln.env(2), 'XData', H.t, 'YData', H.env(:, 2));
            growLim(4, max(H.env(end, :)), [0 1]);

            % mimic + status cards from the breaker commands actually applied
            closed = brk(nAll, :) > 0.5;
            auto = mode(nAll) > 0.5;
            faultOn = isHif && t >= o.TFault;
            cls = round(V.(['Class_' eventLat])(nAll));
            updateMimic(closed, faultOn);
            updateCards(t, closed, auto, faultOn, trip(nAll, evtIdx) > 0.5, cls, H.env(end, :));
            if auto
                setText(hdrMode, 'MODE: AUTO  (breakers follow the ML relays)', C.green);
            else
                setText(hdrMode, 'MODE: MANUAL  (breakers follow Manual_Trip_633 / 675)', C.amber);
            end
            if final
                setText(hdrLive, sprintf('RUN COMPLETE  t = %.2f s', t), C.cyan);
                drawnow;
                wall = toc(stats.wall);
                fprintf(['Live run: %.2f s simulated in %.0f s wall (%.1f s per simulated s); ' ...
                    '%d updates of %.2f s on average.\n'], t, wall, wall / max(t, eps), stats.n + 1, ...
                    (stats.tPoll + toc(tPoll)) / (stats.n + 1));
            else
                setText(hdrLive, sprintf('LIVE  t = %.2f s / %g s', t, stopTime), C.green);
                drawnow limitrate;
            end
        catch err
            if ~warned
                warned = true;
                warning('live_control_center:Update', 'Live view update failed: %s', err.message);
            end
        end
        d = toc(tPoll);
        stats.n = stats.n + 1;
        stats.tPoll = stats.tPoll + d;
        stats.tMax = max(stats.tMax, d);
        stats.last = d;
        stats.lastEnd = tic;
    end

    % ==================================================================
    function newRun(run)
        % A new simulation run started: reset the display.
        runId = run.ID;
        sig = cell2struct(repmat({[]}, numel(SIGNALS), 1), SIGNALS, 1);
        nDone = 0;
        H = struct('t', zeros(0, 1), 'env', zeros(0, 2), 'trip', zeros(0, 2), 'brk', zeros(0, 2));
        lim = [1 1 200];
        set(ax(1), 'YLim', [-1 1]);
        set(ax(2), 'YLim', [-1 1]);
        set(ax(4), 'YLim', [0 200]);
        tIso = NaN;
        isoBy = '';
        tripSeen = [false false];
        delete(markers(isgraphics(markers)));
        markers = gobjects(0);
        mimicKey = '';
        stopTime = str2double(get_param(sys, 'StopTime'));
        set([ax(3) ax(4)], 'XLim', [0 stopTime]);
        stats = struct('n', 0, 'tPoll', 0, 'tMax', 0, 'last', 0, 'wall', tic, 'lastEnd', tic);
    end

    function h = trimHistory(h, t0)
        % Drop history samples at or after t0 (re-read after a short read).
        keepRows = h.t < t0;
        h.t = h.t(keepRows);
        h.env = h.env(keepRows, :);
        h.trip = h.trip(keepRows, :);
        h.brk = h.brk(keepRows, :);
    end

    function growLim(a, v, shape)
        % Enlarge a pane's y-range (with headroom) only when the data outgrow it.
        i = min(a, 3);
        if v > lim(i)
            lim(i) = 1.3 * v;
            set(ax(a), 'YLim', lim(i) * shape);
        end
    end

    % ==================================================================
    function updateCards(t, closed, auto, faultOn, relayEvt, cls, env)
        if faultOn && closed(evtIdx)
            if relayEvt && ~auto
                setText(cards(1), 'HIF DETECTED - TRIP HELD (MANUAL)', C.red);
            elseif relayEvt
                setText(cards(1), 'HIF DETECTED - TRIPPING', C.red);
            else
                setText(cards(1), 'HIF ACTIVE - RELAY EVALUATING', C.amber);
            end
        elseif faultOn
            setText(cards(1), 'ISOLATED / SECURE', C.green);
        elseif all(closed)
            setText(cards(1), 'NORMAL / SECURE', C.green);
        else
            setText(cards(1), sprintf('SECURE - LATERAL OPEN\n(MANUAL)'), C.amber);
        end

        if faultOn
            setText(cards(2), sprintf('Bus %s | %s', bus, latName(bus)), C.text);
        else
            setText(cards(2), 'None', C.text);
        end

        clsText = classNames{min(max(cls, 0), 4) + 1};
        if faultOn
            setText(cards(3), sprintf('%s (relay %s)\ntrue: HIF phase %s', clsText, eventLat, phase), C.text);
        else
            setText(cards(3), sprintf('%s (relay %s)', clsText, eventLat), C.text);
        end

        if ~isnan(tIso)
            ms = 1e3 * (tIso - o.TFault);
            if startsWith(isoBy, 'relay')
                setText(cards(4), sprintf('%.0f ms  (%.1f cycles)\nby %s', ms, ms / (1e3 / 60), isoBy), C.cyan);
            else
                setText(cards(4), sprintf('isolated %.0f ms after inception\nby %s', ms, isoBy), C.cyan);
            end
        elseif faultOn
            setText(cards(4), sprintf('Clearing...  %.0f ms', 1e3 * (t - o.TFault)), C.amber);
        else
            setText(cards(4), '-', C.text);
        end

        if closed(othIdx) && faultOn
            setText(cards(5), sprintf('%s:\nRESTRAINED (energized)', latName(otherLat)), C.text);
        elseif closed(othIdx)
            setText(cards(5), sprintf('%s:\nNORMAL (energized)', latName(otherLat)), C.text);
        elseif auto
            setText(cards(5), sprintf('%s:\nTRIPPED by relay', latName(otherLat)), C.red);
        else
            setText(cards(5), sprintf('%s:\nOPEN (operator)', latName(otherLat)), C.amber);
        end

        setText(cards(6), sprintf('L633 %.1f A  |  L675 %.1f A', env(1), env(2)), C.text);
    end

    function setText(h, s, col)
        % Touch a text object only when its content or colour changes (the
        % last string set is kept in UserData: multi-line strings come back
        % from the String property in a different shape).
        if ~isequal(h.UserData, s) || ~isequal(h.Color, col)
            set(h, 'String', s, 'Color', col, 'UserData', s);
        end
    end

    % ==================================================================
    function updateMimic(closed, faultOn)
        stateKey = sprintf('%d%d%d', closed, faultOn);
        if strcmp(stateKey, mimicKey)
            return;
        end
        mimicKey = stateKey;
        set(M.edge, 'Color', C.edge, 'LineStyle', '-');
        nodeKeys = M.nodeMarker.keys;
        for q = 1:numel(nodeKeys)
            set(M.nodeMarker(nodeKeys{q}), 'MarkerFaceColor', C.node);
        end
        set(M.arc, 'XData', NaN, 'YData', NaN);
        set(M.arcText, 'String', '');
        lats = {'633', '675'};
        openNames = {};
        for q = 1:2
            lat = lats{q};
            idx = ismember(M.edgeNames, M.lateralEdges(lat));
            nodes = M.lateralNodes(lat);
            isEvt = faultOn && strcmp(lat, bus);
            if closed(q)
                set(M.brkMarker(lat), 'MarkerFaceColor', C.green, 'MarkerEdgeColor', C.text);
                set(M.brkText(lat), 'String', 'CLOSED', 'Color', C.green);
                if isEvt
                    set(M.edge(idx), 'Color', C.amber);
                    cellfun(@(nd) set(M.nodeMarker(nd), 'MarkerFaceColor', C.amber), nodes);
                end
            else
                openNames{end + 1} = lat; %#ok<AGROW>
                set(M.brkMarker(lat), 'MarkerFaceColor', C.bg, 'MarkerEdgeColor', C.red);
                set(M.brkText(lat), 'String', 'OPEN', 'Color', C.red);
                set(M.edge(idx), 'Color', C.dead, 'LineStyle', '--');
                cellfun(@(nd) set(M.nodeMarker(nd), 'MarkerFaceColor', C.dead), nodes);
            end
            if isEvt
                qb = M.node(bus);
                if closed(q)
                    set(M.arc, 'XData', qb(1), 'YData', qb(2) + 0.42, 'MarkerFaceColor', C.amber, 'MarkerEdgeColor', C.red);
                    set(M.arcText, 'Position', [qb(1), qb(2) + 0.78, 0], 'String', ...
                        sprintf('ARC  phase %s', phase), 'Color', C.amber);
                else
                    set(M.arc, 'XData', qb(1), 'YData', qb(2) + 0.42, 'MarkerFaceColor', C.dead, 'MarkerEdgeColor', C.red);
                    set(M.arcText, 'Position', [qb(1), qb(2) + 0.78, 0], 'String', 'ISOLATED', 'Color', C.red);
                end
            end
        end
        if faultOn && closed(evtIdx)
            set(M.note, 'String', sprintf('HIF on %s - lateral still energized', bus));
        elseif ~isempty(openNames)
            set(M.note, 'String', sprintf('Lateral %s de-energized; rest of feeder in service', strjoin(openNames, ' + ')));
        else
            set(M.note, 'String', 'All sections energized');
        end
    end

    % ==================================================================
    function [axs, L] = drawPanes()
        box = [0.47 0.05 0.515 0.83];
        gap = 0.05;
        h = (box(4) - 3 * gap) / 4;
        titles = {sprintf('Substation feeder current  I_{650}  (A)  -  last %g s', o.Window), ...
            sprintf('Digital-twin residual  \\DeltaI = I_{phys} - I_{twin}  (A)  -  lateral %s, last %g s', eventLat, o.Window), ...
            'Relay trip commands (solid) and breaker open commands (dashed)', ...
            'Lateral head currents (1-cycle RMS, max phase)  (A)'};
        axs = gobjects(4, 1);
        for a = 1:4
            axs(a) = axes(fig, 'Position', [box(1), box(2) + box(4) - a * h - (a - 1) * gap, box(3), h], ...
                'Color', C.panel, 'XColor', C.muted, 'YColor', C.muted, 'GridColor', C.grid, ...
                'GridAlpha', 0.6, 'FontSize', 8.5, 'XLim', [0 o.StopTime]);
            hold(axs(a), 'on');
            grid(axs(a), 'on');
            title(axs(a), titles{a}, 'Color', C.text, 'FontSize', 10, 'FontWeight', 'normal');
        end
        set([axs(1) axs(2)], 'XLim', [-o.Window 0], 'YLim', [-1 1]);
        xlabel(axs(4), 'Simulation time (s)    [panes 1-2: seconds before the current simulation time]', 'Color', C.muted);
        L.i650 = gobjects(3, 1);
        L.res = gobjects(3, 1);
        L.oth = gobjects(3, 1);
        for q = 1:3
            L.i650(q) = plot(axs(1), NaN, NaN, 'Color', C.phase(q, :), 'LineWidth', 1);
            L.oth(q) = plot(axs(2), NaN, NaN, 'Color', C.dim, 'LineWidth', 0.8);
        end
        for q = 1:3
            L.res(q) = plot(axs(2), NaN, NaN, 'Color', C.phase(q, :), 'LineWidth', 1.1);
        end
        L.trip(1) = stairs(axs(3), NaN, NaN, 'Color', C.cyan, 'LineWidth', 2);
        L.trip(2) = stairs(axs(3), NaN, NaN, 'Color', C.magenta, 'LineWidth', 2);
        L.brk(1) = stairs(axs(3), NaN, NaN, '--', 'Color', C.cyan, 'LineWidth', 1.2);
        L.brk(2) = stairs(axs(3), NaN, NaN, '--', 'Color', C.magenta, 'LineWidth', 1.2);
        set(axs(3), 'YLim', [-0.15 1.25], 'YTick', [0 1], 'YTickLabel', {'0', 'TRIP / OPEN'});
        L.env(1) = plot(axs(4), NaN, NaN, 'Color', C.cyan, 'LineWidth', 2);
        L.env(2) = plot(axs(4), NaN, NaN, 'Color', C.magenta, 'LineWidth', 2);
        set(axs(4), 'YLim', [0 200]);
        if isHif || strcmp(key, 'CAP675')
            for a = 3:4
                xline(axs(a), o.TFault, '--', 'Color', C.amber, 'LineWidth', 1);
            end
        end
        % static colour keys instead of legends (legends re-layout on every redraw)
        keyText(axs(1), {'Phase A', 'Phase B', 'Phase C'}, {C.phase(1, :), C.phase(2, :), C.phase(3, :)});
        keyText(axs(2), {sprintf('L%s A', eventLat), 'B', 'C', sprintf('grey: L%s', otherLat)}, ...
            {C.phase(1, :), C.phase(2, :), C.phase(3, :), C.dim + 0.2});
        keyText(axs(3), {'Relay / Brk 633', 'Relay / Brk 675'}, {C.cyan, C.magenta});
        keyText(axs(4), {'Lateral 632-633', 'Lateral 692-675'}, {C.cyan, C.magenta});
        L.now = text(axs(1), 0.01, 0.9, 't = 0.00 s', 'Units', 'normalized', 'Color', C.muted, ...
            'FontSize', 8, 'Interpreter', 'none');
    end

    function keyText(a, labels, cols)
        % One right-aligned, multi-coloured key line (TeX colour switches).
        parts = cellfun(@(s, c) sprintf('\\color[rgb]{%.2f,%.2f,%.2f}%s', min(c, 1), s), labels, cols, ...
            'UniformOutput', false);
        text(a, 0.99, 0.9, strjoin(parts, '   '), 'Units', 'normalized', 'FontSize', 8, ...
            'FontWeight', 'bold', 'HorizontalAlignment', 'right', 'Interpreter', 'tex');
    end
end

%% ======================================================================
function M = drawMimic(ax, C)
% Same topology mimic as run_final_review_demo.m (Figure 4.9).
M.node = containers.Map( ...
    {'650', '632', '633', '634', '645', '646', '671', '684', '611', '652', '680', '692', '675'}, ...
    {[0 4.0], [0 3.0], [1.25 3.0], [2.35 3.0], [-1.25 3.0], [-2.35 3.0], [0 1.65], ...
     [-1.25 1.65], [-2.35 1.65], [-1.25 0.55], [0 0.55], [1.25 1.65], [2.35 1.65]});
edges = {'650', '632'; '632', '633'; '633', '634'; '632', '645'; '645', '646'; '632', '671'; ...
    '671', '684'; '684', '611'; '684', '652'; '671', '680'; '671', '692'; '692', '675'};
M.edgeNames = strcat(edges(:, 1), '-', edges(:, 2));
M.edge = gobjects(size(edges, 1), 1);
for e = 1:size(edges, 1)
    a = M.node(edges{e, 1});
    b = M.node(edges{e, 2});
    M.edge(e) = plot(ax, [a(1) b(1)], [a(2) b(2)], '-', 'Color', C.edge, 'LineWidth', 3.5);
end
plot(ax, [0 0], [4.0 4.45], '-', 'Color', C.edge, 'LineWidth', 3.5);
plot(ax, 0, 4.5, 'o', 'MarkerSize', 16, 'MarkerFaceColor', C.panel, 'MarkerEdgeColor', C.text, 'LineWidth', 1.5);
text(ax, 0.2, 4.5, 'Substation 4.16 kV', 'Color', C.muted, 'FontSize', 9);
xm = mean([M.node('633'); M.node('634')]);
plot(ax, xm(1) - 0.07, xm(2), 'o', 'MarkerSize', 11, 'MarkerEdgeColor', C.text, 'MarkerFaceColor', C.panel, 'LineWidth', 1.2);
plot(ax, xm(1) + 0.07, xm(2), 'o', 'MarkerSize', 11, 'MarkerEdgeColor', C.text, 'MarkerFaceColor', C.panel, 'LineWidth', 1.2);
text(ax, xm(1) + 0.05, xm(2) + 0.24, 'XFM 4.16/0.48 kV', 'Color', C.muted, 'FontSize', 7, 'HorizontalAlignment', 'center');
names = M.node.keys;
M.nodeMarker = containers.Map();
for q = 1:numel(names)
    pt = M.node(names{q});
    M.nodeMarker(names{q}) = plot(ax, pt(1), pt(2), 'o', 'MarkerSize', 9, ...
        'MarkerFaceColor', C.node, 'MarkerEdgeColor', C.bg, 'LineWidth', 1);
    text(ax, pt(1), pt(2) - 0.22, names{q}, 'Color', C.text, 'FontSize', 9, ...
        'HorizontalAlignment', 'center', 'FontWeight', 'bold');
end
M.brkPos = containers.Map({'633', '675'}, {[0.55 3.0], [1.75 1.65]});
M.brkMarker = containers.Map();
M.brkText = containers.Map();
for lat = {'633', '675'}
    pt = M.brkPos(lat{1});
    M.brkMarker(lat{1}) = plot(ax, pt(1), pt(2), 's', 'MarkerSize', 15, ...
        'MarkerFaceColor', C.green, 'MarkerEdgeColor', C.text, 'LineWidth', 1.5);
    M.brkText(lat{1}) = text(ax, pt(1), pt(2) + 0.27, 'CLOSED', 'Color', C.green, ...
        'FontSize', 8, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
end
text(ax, 0.55, 2.55, 'Brk 632-633', 'Color', C.muted, 'FontSize', 7.5, 'HorizontalAlignment', 'center');
text(ax, 1.75, 1.2, 'Brk 692-675', 'Color', C.muted, 'FontSize', 7.5, 'HorizontalAlignment', 'center');
M.arc = plot(ax, NaN, NaN, 'p', 'MarkerSize', 24, 'MarkerFaceColor', C.amber, ...
    'MarkerEdgeColor', C.red, 'LineWidth', 1.5);
M.arcText = text(ax, NaN, NaN, '', 'Color', C.amber, 'FontSize', 10, 'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center');
M.note = text(ax, -2.8, 0.15, 'All sections energized', 'Color', C.muted, 'FontSize', 9);
M.lateralEdges = containers.Map({'633', '675'}, {{'632-633', '633-634'}, {'692-675'}});
M.lateralNodes = containers.Map({'633', '675'}, {{'633', '634'}, {'675'}});
end

function C = palette(themeName)
% 'dark': control-room palette of run_final_review_demo.m.
% 'light': white background, dark lines and text, high-contrast traces.
if nargin > 0 && strcmpi(themeName, 'light')
    C.theme   = 'light';
    C.bg      = [1 1 1];
    C.panel   = [1 1 1];
    C.card    = [0.965 0.97 0.98];
    C.grid    = [0.78 0.80 0.83];
    C.text    = [0.05 0.05 0.08];
    C.muted   = [0.25 0.27 0.30];
    C.dim     = [0.62 0.64 0.67];
    C.dead    = [0.72 0.74 0.77];
    C.green   = [0.00 0.55 0.20];
    C.amber   = [0.85 0.42 0.00];
    C.red     = [0.80 0.05 0.05];
    C.cyan    = [0.00 0.28 0.75];
    C.magenta = [0.00 0.50 0.20];
    C.phase   = [0.80 0.08 0.08; 0.05 0.55 0.15; 0.05 0.25 0.80];
    C.edge    = [0.12 0.13 0.16];
    C.node    = [0.12 0.13 0.16];
    return
end
C.theme   = 'dark';
C.bg      = [0.055 0.071 0.098];
C.panel   = [0.098 0.122 0.165];
C.grid    = [0.22 0.26 0.32];
C.text    = [0.88 0.91 0.95];
C.muted   = [0.58 0.64 0.72];
C.dim     = [0.32 0.36 0.42];
C.dead    = [0.36 0.40 0.46];
C.green   = [0.27 0.80 0.50];
C.amber   = [1.00 0.72 0.18];
C.red     = [0.96 0.33 0.30];
C.cyan    = [0.33 0.78 0.96];
C.magenta = [0.86 0.47 0.95];
C.phase   = [0.96 0.43 0.36; 0.98 0.82 0.32; 0.38 0.68 0.98];
C.card    = C.panel;
C.edge    = C.green;
C.node    = C.green;
end
