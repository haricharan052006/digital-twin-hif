function r = run_final_review_demo(scenarioName, varargin)
%RUN_FINAL_REVIEW_DEMO  One-click Review 2 demonstration of the closed-loop
% digital-twin HIF protection (ieee13_hif_twin_system.slx).
%
%   run_final_review_demo('633A')     typical HIF, Bus 633 phase A
%                                     (Vp 1500 V, Vn 2000 V, Rp 200, Rn 300 Ohm)
%   run_final_review_demo('675C')     weak / boundary HIF, Bus 675 phase C
%                                     (Vp 2400 V, Vn 2500 V, Rp = Rn = 2000 Ohm)
%   run_final_review_demo('cap675')   675 capacitor bank switching (benign)
%   run_final_review_demo('healthy')  no event
%   Any other '<bus><phase>' code ('633B', '675A', ...) runs a typical HIF.
%   All events start at t = 0.10 s; runs are 0.30 s.
%
%   r = run_final_review_demo(..., 'Dashboard', true, 'Animate', true, ...
%                             'ExportPng', false, 'ExportFile', '')
%     Dashboard  open the control-center figure (default true)
%     Animate    replay the run with a moving time cursor and live mimic /
%                telemetry updates (default true)
%     ExportPng  also save the publication 4-pane waveform figure to
%                results/final_demo_waveform_<scenario>.png (default false)
%     ExportFile override that PNG path
%   r is the run_twin_isolation_case result (raw waveforms in r.time,
%   r.I_633_physical, r.dI_675, r.trip_633, ...) plus r.summary.
%
% Everything here runs AFTER the simulation finishes: no callback, scope
% or block is added to the model, so batch runs (generate_dataset.m,
% verify_twin_isolation.m) and solver speed are unaffected.

p = inputParser;
p.addParameter('Dashboard', true);
p.addParameter('Animate', true);
p.addParameter('ExportPng', false);
p.addParameter('ExportFile', '');
p.parse(varargin{:});
opt = p.Results;

projectRoot = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(projectRoot, 'scripts'), fullfile(projectRoot, 'models'));

sc = scenarioSpec(scenarioName);
fprintf('=== Review demo: %s ===\n', sc.description);
r = run_twin_isolation_case(sc.type, sc.args{:});
s = summarize(r, sc);
r.summary = s;

fprintf('  System state:          %s\n', s.state);
fprintf('  Faulted bus / lateral: %s\n', s.faultText);
fprintf('  Classification:        %s\n', s.classText);
fprintf('  Clearance:             %s\n', s.clearText);
fprintf('  Adjacent lateral:      %s\n', s.adjacentText);

if opt.Dashboard
    drawDashboard(r, sc, s, opt.Animate);
end
if opt.ExportPng
    f = opt.ExportFile;
    if isempty(f)
        f = fullfile(projectRoot, 'results', sprintf('final_demo_waveform_%s.png', sc.key));
    end
    exportWaveforms(r, sc, s, f);
    fprintf('  Waveform figure saved: %s\n', f);
end
end

%% ======================================================================
function sc = scenarioSpec(name)
key = char(string(name));
typical = {'Vp', 1500, 'Vn', 2000, 'Rp', 200, 'Rn', 300};
weak    = {'Vp', 2400, 'Vn', 2500, 'Rp', 2000, 'Rn', 2000};
sc.key = key;
sc.tEvent = 0.10;
switch lower(key)
    case 'healthy'
        sc.type = 'none';  sc.bus = '';   sc.phase = '';
        sc.args = {};
        sc.description = 'Healthy feeder (no event)';
    case 'cap675'
        sc.type = 'cap675'; sc.bus = '';  sc.phase = '';
        sc.args = {'TEvent', sc.tEvent};
        sc.description = 'Capacitor bank 675 switched out at 100 ms (benign transient)';
    otherwise
        tok = regexp(upper(key), '^(633|675)([ABC])$', 'tokens', 'once');
        if isempty(tok)
            error('run_final_review_demo:BadScenario', ...
                'Scenario must be ''633A''..''675C'', ''cap675'' or ''healthy''.');
        end
        sc.type = 'hif'; sc.bus = tok{1}; sc.phase = tok{2};
        sc.key = [tok{1} tok{2}];
        if strcmp(sc.key, '675C')
            arc = weak;
            kind = 'Weak/boundary';
        else
            arc = typical;
            kind = 'Typical';
        end
        sc.args = [{'Bus', sc.bus, 'Phase', sc.phase, 'TEvent', sc.tEvent}, arc];
        sc.arc = cell2struct(arc(2:2:end), arc(1:2:end), 2);
        sc.description = sprintf('%s HIF at Bus %s phase %s (Vp %d V, Vn %d V, Rp %d, Rn %d Ohm)', ...
            kind, sc.bus, sc.phase, sc.arc.Vp, sc.arc.Vn, sc.arc.Rp, sc.arc.Rn);
end
end

%% ======================================================================
function s = summarize(r, sc)
lateralName = containers.Map({'633', '675'}, {'Lateral 632-633', 'Lateral 692-675'});
classNames = {'Normal', 'Switching transient', 'HIF phase A', 'HIF phase B', 'HIF phase C'};
s.tEvent = sc.tEvent;
s.tTrip = min([r.tripTime633, r.tripTime675]);
s.isHif = strcmp(sc.type, 'hif');
if s.isHif
    s.eventLat = sc.bus;
elseif strcmp(sc.type, 'cap675')
    s.eventLat = '675';
else
    s.eventLat = '633';
end
s.otherLat = char(setdiff({'633', '675'}, s.eventLat));

% Relay classification on the event lateral: most frequent decision
% between the event and the trip (or the end of the run).
cls = r.(['class_' s.eventLat]);
tEnd = s.tTrip;
if isnan(tEnd)
    tEnd = r.time(end);
end
win = cls(r.time >= s.tEvent & r.time <= tEnd);
nonNormal = win(win > 0);
if isempty(nonNormal)
    s.classCode = 0;
else
    s.classCode = mode(nonNormal);
end
s.classText = classNames{s.classCode + 1};
if s.isHif
    s.classText = sprintf('%s (relay) | true: HIF phase %s', s.classText, sc.phase);
elseif s.classCode == 1
    s.classText = 'Switching transient - benign';
end

tripped = r.tripped;
if s.isHif
    s.faultText = sprintf('Bus %s | %s', sc.bus, lateralName(sc.bus));
else
    s.faultText = 'None';
end
if strcmp(tripped, 'none')
    if s.isHif
        s.state = 'HIF NOT CLEARED';
    else
        s.state = 'SECURE / NORMAL';
    end
    s.clearText = 'No trip';
    s.clearMs = NaN;
else
    s.state = 'ISOLATED / SECURE';
    s.clearMs = 1e3 * (s.tTrip - s.tEvent);
    s.clearText = sprintf('%.0f ms  (%.1f cycles @ 60 Hz)', s.clearMs, s.clearMs / (1e3 / 60));
end
otherTripped = contains(tripped, s.otherLat);
if otherTripped
    s.adjacentText = sprintf('%s TRIPPED (sympathetic)', lateralName(s.otherLat));
elseif s.isHif
    s.adjacentText = sprintf('%s: RESTRAINED (energized)', lateralName(s.otherLat));
else
    s.adjacentText = 'Both laterals: NORMAL (energized)';
end
s.trippedLat = '';
if ~strcmp(tripped, 'none') && ~otherTripped
    s.trippedLat = s.eventLat;
end
lastCyc = r.time > r.time(end) - 1/60;
s.endRms = struct('L633', max(rms(r.I_633_physical(lastCyc, :))), ...
    'L675', max(rms(r.I_675_physical(lastCyc, :))));
preCyc = r.time > s.tEvent - 1/60 & r.time <= s.tEvent;
s.preRms = struct('L633', max(rms(r.I_633_physical(preCyc, :))), ...
    'L675', max(rms(r.I_675_physical(preCyc, :))));
end

%% ======================================================================
function drawDashboard(r, sc, s, animate)
C = palette('dark');
fig = figure('Name', ['HIF Digital-Twin Control Center - ' sc.key], 'NumberTitle', 'off', ...
    'Color', C.bg, 'Position', [60 60 1600 900], 'MenuBar', 'none', 'ToolBar', 'figure');

annotation(fig, 'textbox', [0.015 0.935 0.75 0.055], 'String', ...
    'IEEE 13-Node Feeder  |  Digital-Twin HIF Protection Control Center', 'Color', C.text, ...
    'FontSize', 17, 'FontWeight', 'bold', 'EdgeColor', 'none', 'VerticalAlignment', 'middle');
annotation(fig, 'textbox', [0.015 0.905 0.75 0.035], 'String', sc.description, ...
    'Color', C.muted, 'FontSize', 11, 'EdgeColor', 'none', 'VerticalAlignment', 'middle');
annotation(fig, 'textbox', [0.76 0.925 0.225 0.06], 'String', ...
    sprintf('ieee13\\_hif\\_twin\\_system.slx\nTs = 50 \\mus  |  db4 DWT + Random Forest'), ...
    'Color', C.muted, 'FontSize', 9, 'EdgeColor', 'none', 'HorizontalAlignment', 'right', ...
    'VerticalAlignment', 'middle');

% ---------------- topology mimic
axM = axes(fig, 'Position', [0.02 0.40 0.40 0.45], 'Color', C.panel, 'XColor', 'none', ...
    'YColor', 'none', 'XLim', [-2.9 2.9], 'YLim', [0.0 4.75]);
hold(axM, 'on');
title(axM, 'Feeder Topology Mimic', 'Color', C.text, 'FontSize', 12);
M = drawMimic(axM, C);

% ---------------- telemetry cards
cardTitles = {'SYSTEM STATE', 'FAULTED BUS & LATERAL', 'EVENT CLASSIFICATION', ...
    'CLEARANCE SPEED', 'ADJACENT LATERAL SECURITY', 'BRANCH LOAD (end of run)'};
cardPos = [0.02 0.255; 0.22 0.255; 0.02 0.14; 0.22 0.14; 0.02 0.025; 0.22 0.025];
cards = gobjects(numel(cardTitles), 1);
for k = 1:numel(cardTitles)
    pos = [cardPos(k, :) 0.195 0.105];
    annotation(fig, 'rectangle', pos, 'FaceColor', C.panel, 'Color', C.grid, 'LineWidth', 1);
    annotation(fig, 'textbox', [pos(1) + 0.008, pos(2) + 0.062, pos(3) - 0.016, 0.035], ...
        'String', cardTitles{k}, 'Color', C.muted, 'FontSize', 8.5, 'FontWeight', 'bold', ...
        'EdgeColor', 'none', 'VerticalAlignment', 'middle');
    cards(k) = annotation(fig, 'textbox', [pos(1) + 0.008, pos(2) + 0.006, pos(3) - 0.016, 0.06], ...
        'String', '-', 'Color', C.text, 'FontSize', 11, 'FontWeight', 'bold', ...
        'EdgeColor', 'none', 'VerticalAlignment', 'middle', 'Interpreter', 'none');
end

% ---------------- waveforms
W = drawWaveformPanes(fig, r, s, C, [0.47 0.05 0.515 0.85]);

% ---------------- replay
if animate
    frames = linspace(0, r.time(end), 90);
else
    frames = r.time(end);
end
for t = frames
    idx = r.time <= t;
    for k = 1:numel(W.lines)
        set(W.lines(k), 'XData', W.x{k}(idx), 'YData', W.y{k}(idx));
    end
    set(W.cursor, 'Value', 1e3 * t);
    [stage, cardText] = stageAt(t, s);
    updateMimic(M, stage, sc, s, C);
    for k = 1:numel(cards)
        set(cards(k), 'String', cardText{k}, 'Color', cardColor(k, stage, s, C));
    end
    if animate
        drawnow;
        pause(0.02);
    end
end
set(W.cursor, 'Visible', 'off');
drawnow;
end

%% ======================================================================
function [stage, txt] = stageAt(t, s)
% Stage of the event at time t and the telemetry text shown then.
if t < s.tEvent
    stage = 'pre';
elseif isnan(s.tTrip) || t < s.tTrip
    stage = 'event';
else
    stage = 'isolated';
end
txt = cell(6, 1);
switch stage
    case 'pre'
        txt(1:5) = {'MONITORING / SECURE', 'None', 'Normal', '-', 'Both laterals: NORMAL'};
    case 'event'
        if s.isHif
            txt{1} = 'HIF ACTIVE - RELAY EVALUATING';
        else
            txt{1} = s.state;
        end
        txt(2:5) = {s.faultText, s.classText, 'Clearing...', s.adjacentText};
        if ~s.isHif || isnan(s.tTrip)
            txt{4} = s.clearText;
        end
    case 'isolated'
        txt(1:5) = {s.state, s.faultText, s.classText, s.clearText, s.adjacentText};
end
if strcmp(stage, 'isolated') || (~strcmp(stage, 'pre') && isnan(s.tTrip))
    txt{6} = sprintf('L633 %.1f A  |  L675 %.1f A', s.endRms.L633, s.endRms.L675);
else
    txt{6} = sprintf('L633 %.1f A  |  L675 %.1f A', s.preRms.L633, s.preRms.L675);
end
end

function c = cardColor(k, stage, s, C)
c = C.text;
if k == 1
    switch stage
        case 'pre'
            c = C.green;
        case 'event'
            if s.isHif
                c = C.amber;
            else
                c = C.green;
            end
        case 'isolated'
            c = C.green;
    end
    if contains(s.state, 'NOT CLEARED') && ~strcmp(stage, 'pre')
        c = C.red;
    end
elseif k == 5 && contains(s.adjacentText, 'TRIPPED')
    c = C.red;
elseif k == 4 && strcmp(stage, 'isolated')
    c = C.cyan;
end
end

%% ======================================================================
function M = drawMimic(ax, C)
M.node = containers.Map( ...
    {'650', '632', '633', '634', '645', '646', '671', '684', '611', '652', '680', '692', '675'}, ...
    {[0 4.0], [0 3.0], [1.25 3.0], [2.35 3.0], [-1.25 3.0], [-2.35 3.0], [0 1.65], ...
     [-1.25 1.65], [-2.35 1.65], [-1.25 0.55], [0 0.55], [1.25 1.65], [2.35 1.65]});
edges = {'650', '632'; '632', '633'; '633', '634'; '632', '645'; '645', '646'; '632', '671'; ...
    '671', '684'; '684', '611'; '684', '652'; '671', '680'; '671', '692'; '692', '675'};
M.edgeNames = strcat(edges(:, 1), '-', edges(:, 2));
M.edge = gobjects(size(edges, 1), 1);
for k = 1:size(edges, 1)
    a = M.node(edges{k, 1});
    b = M.node(edges{k, 2});
    M.edge(k) = plot(ax, [a(1) b(1)], [a(2) b(2)], '-', 'Color', C.green, 'LineWidth', 3.5);
end

% substation source + transformer + tie symbols
plot(ax, [0 0], [4.0 4.45], '-', 'Color', C.green, 'LineWidth', 3.5);
plot(ax, 0, 4.5, 'o', 'MarkerSize', 16, 'MarkerFaceColor', C.panel, 'MarkerEdgeColor', C.text, 'LineWidth', 1.5);
text(ax, 0.2, 4.5, 'Substation 4.16 kV', 'Color', C.muted, 'FontSize', 9);
xm = mean([M.node('633'); M.node('634')]);
plot(ax, xm(1) - 0.07, xm(2), 'o', 'MarkerSize', 11, 'MarkerEdgeColor', C.text, 'MarkerFaceColor', C.panel, 'LineWidth', 1.2);
plot(ax, xm(1) + 0.07, xm(2), 'o', 'MarkerSize', 11, 'MarkerEdgeColor', C.text, 'MarkerFaceColor', C.panel, 'LineWidth', 1.2);
text(ax, xm(1) + 0.05, xm(2) + 0.24, 'XFM 4.16/0.48 kV', 'Color', C.muted, 'FontSize', 7, 'HorizontalAlignment', 'center');

keys = M.node.keys;
M.nodeMarker = containers.Map();
for k = 1:numel(keys)
    q = M.node(keys{k});
    M.nodeMarker(keys{k}) = plot(ax, q(1), q(2), 'o', 'MarkerSize', 9, ...
        'MarkerFaceColor', C.green, 'MarkerEdgeColor', C.bg, 'LineWidth', 1);
    text(ax, q(1), q(2) - 0.22, keys{k}, 'Color', C.text, 'FontSize', 9, ...
        'HorizontalAlignment', 'center', 'FontWeight', 'bold');
end

% lateral breakers (square: filled = closed, hollow red = open)
M.brkPos = containers.Map({'633', '675'}, {[0.55 3.0], [1.75 1.65]});
M.brkMarker = containers.Map();
M.brkText = containers.Map();
for lat = {'633', '675'}
    q = M.brkPos(lat{1});
    M.brkMarker(lat{1}) = plot(ax, q(1), q(2), 's', 'MarkerSize', 15, ...
        'MarkerFaceColor', C.green, 'MarkerEdgeColor', C.text, 'LineWidth', 1.5);
    M.brkText(lat{1}) = text(ax, q(1), q(2) + 0.27, 'CLOSED', 'Color', C.green, ...
        'FontSize', 8, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
end
text(ax, 0.55, 2.55, 'Brk 632-633', 'Color', C.muted, 'FontSize', 7.5, 'HorizontalAlignment', 'center');
text(ax, 1.75, 1.2, 'Brk 692-675', 'Color', C.muted, 'FontSize', 7.5, 'HorizontalAlignment', 'center');

M.arc = plot(ax, NaN, NaN, 'p', 'MarkerSize', 24, 'MarkerFaceColor', C.amber, ...
    'MarkerEdgeColor', C.red, 'LineWidth', 1.5);
M.arcText = text(ax, NaN, NaN, '', 'Color', C.amber, 'FontSize', 10, 'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center');
M.note = text(ax, -2.8, 0.15, '', 'Color', C.muted, 'FontSize', 9);

M.lateralEdges = containers.Map({'633', '675'}, {{'632-633', '633-634'}, {'692-675'}});
M.lateralNodes = containers.Map({'633', '675'}, {{'633', '634'}, {'675'}});
end

function updateMimic(M, stage, sc, s, C)
% Reset to energized, then apply the event / isolation state.
set(M.edge, 'Color', C.green, 'LineStyle', '-');
keys = M.nodeMarker.keys;
for k = 1:numel(keys)
    set(M.nodeMarker(keys{k}), 'MarkerFaceColor', C.green);
end
for lat = {'633', '675'}
    set(M.brkMarker(lat{1}), 'MarkerFaceColor', C.green, 'MarkerEdgeColor', C.text);
    set(M.brkText(lat{1}), 'String', 'CLOSED', 'Color', C.green);
end
set(M.arc, 'XData', NaN, 'YData', NaN);
set(M.arcText, 'String', '');
set(M.note, 'String', 'All sections energized');

if strcmp(stage, 'pre')
    return;
end
if s.isHif
    bus = sc.bus;
    q = M.node(bus);
    edgeIdx = ismember(M.edgeNames, M.lateralEdges(bus));
    nodes = M.lateralNodes(bus);
    if strcmp(stage, 'event')
        set(M.edge(edgeIdx), 'Color', C.amber);
        for k = 1:numel(nodes)
            set(M.nodeMarker(nodes{k}), 'MarkerFaceColor', C.amber);
        end
        set(M.arc, 'XData', q(1), 'YData', q(2) + 0.42);
        set(M.arcText, 'Position', [q(1), q(2) + 0.78, 0], 'String', ...
            sprintf('ARC  phase %s', sc.phase), 'Color', C.amber);
        set(M.note, 'String', sprintf('HIF on %s - relay evaluating', bus));
    else
        set(M.edge(edgeIdx), 'Color', C.dead, 'LineStyle', '--');
        for k = 1:numel(nodes)
            set(M.nodeMarker(nodes{k}), 'MarkerFaceColor', C.dead);
        end
        set(M.arc, 'XData', q(1), 'YData', q(2) + 0.42, 'MarkerFaceColor', C.dead, 'MarkerEdgeColor', C.red);
        set(M.arcText, 'Position', [q(1), q(2) + 0.78, 0], 'String', 'ISOLATED', 'Color', C.red);
        if ~isempty(s.trippedLat)
            set(M.brkMarker(s.trippedLat), 'MarkerFaceColor', C.bg, 'MarkerEdgeColor', C.red);
            set(M.brkText(s.trippedLat), 'String', 'OPEN', 'Color', C.red);
        end
        set(M.note, 'String', sprintf('Lateral %s de-energized; rest of feeder in service', bus));
    end
elseif strcmp(sc.type, 'cap675')
    q = M.node('675');
    set(M.arcText, 'Position', [q(1), q(2) + 0.75, 0], 'String', 'CAP BANK SWITCHED', 'Color', C.cyan);
    set(M.note, 'String', 'Benign switching - relays restrained');
end
end

%% ======================================================================
function W = drawWaveformPanes(fig, r, s, C, box)
% Four stacked panes; returns line handles + full data for progressive
% reveal, and the time cursors.
tms = 1e3 * r.time;
gap = 0.05;
h = (box(4) - 3 * gap) / 4;
titles = {'Substation feeder current  I_{650}  (A)', ...
    sprintf('Digital-twin residual  \\DeltaI = I_{phys} - I_{twin}  (A)  -  lateral %s', s.eventLat), ...
    'Relay trip commands', ...
    'Lateral head currents (1-cycle RMS, max phase)  (A)'};
W.lines = gobjects(0);
W.x = {};
W.y = {};
W.cursor = gobjects(0);
ax = gobjects(4, 1);
for k = 1:4
    ax(k) = axes(fig, 'Position', [box(1), box(2) + box(4) - k * h - (k - 1) * gap, box(3), h], ...
        'Color', C.panel, 'XColor', C.muted, 'YColor', C.muted, 'GridColor', C.grid, ...
        'GridAlpha', 0.6, 'FontSize', 8.5, 'XLim', [0 tms(end)]);
    hold(ax(k), 'on');
    grid(ax(k), 'on');
    title(ax(k), titles{k}, 'Color', C.text, 'FontSize', 10, 'FontWeight', 'normal');
    if k < 4
        ax(k).XTickLabel = [];
    else
        xlabel(ax(k), 'Time (ms)', 'Color', C.muted);
    end
end

add = @(a, y, col, w, name) addLine(a, tms, y, col, w, name);
for p = 1:3
    add(ax(1), r.I_650_physical(:, p), C.phase(p, :), 1, sprintf('Phase %c', 'A' + p - 1));
end
lim = max(abs(r.I_650_physical(:)));
ylim(ax(1), 1.15 * lim * [-1 1]);

dI = r.(['dI_' s.eventLat]);
dO = r.(['dI_' s.otherLat]);
for p = 1:3
    add(ax(2), dO(:, p), C.dim, 0.8, '');
end
for p = 1:3
    add(ax(2), dI(:, p), C.phase(p, :), 1.1, sprintf('L%s phase %c', s.eventLat, 'A' + p - 1));
end
lim = max(1, max(abs([dI(:); dO(:)])));
ylim(ax(2), 1.2 * lim * [-1 1]);

add(ax(3), r.trip_633, C.cyan, 2, 'Relay 633');
add(ax(3), r.trip_675 * 0.98, C.magenta, 2, 'Relay 675');
ylim(ax(3), [-0.15 1.25]);
ax(3).YTick = [0 1];
ax(3).YTickLabel = {'0', 'TRIP'};

env = @(I) cycleRmsMaxPhase(I, r.time);
add(ax(4), env(r.I_633_physical), C.cyan, 2, 'Lateral 632-633');
add(ax(4), env(r.I_675_physical), C.magenta, 2, 'Lateral 692-675');
ylim(ax(4), [0 1.2 * max(s.preRms.L675, s.preRms.L633) + 10]);

for k = 1:4
    xline(ax(k), 1e3 * s.tEvent, '--', 'Color', C.amber, 'LineWidth', 1, 'HandleVisibility', 'off');
    if ~isnan(s.tTrip)
        xline(ax(k), 1e3 * s.tTrip, '--', 'Color', C.red, 'LineWidth', 1, 'HandleVisibility', 'off');
    end
    W.cursor(k) = xline(ax(k), 0, '-', 'Color', C.text, 'LineWidth', 1, 'HandleVisibility', 'off');
    legend(ax(k), 'TextColor', C.text, 'Color', C.panel, 'EdgeColor', C.grid, ...
        'Location', 'northeast', 'FontSize', 7.5, 'AutoUpdate', 'off');
end
text(ax(1), 1e3 * s.tEvent + 2, 0.92 * ax(1).YLim(2), 'event', 'Color', C.amber, 'FontSize', 8);
if ~isnan(s.tTrip)
    text(ax(1), 1e3 * s.tTrip + 2, 0.75 * ax(1).YLim(2), 'trip', 'Color', C.red, 'FontSize', 8);
end

    function addLine(a, x, y, col, w, name)
        if isempty(name)
            hl = plot(a, x, y, 'Color', col, 'LineWidth', w, 'HandleVisibility', 'off');
        else
            hl = plot(a, x, y, 'Color', col, 'LineWidth', w, 'DisplayName', name);
        end
        W.lines(end + 1) = hl;
        W.x{end + 1} = x;
        W.y{end + 1} = y;
    end
end

%% ======================================================================
function exportWaveforms(r, sc, s, outFile)
% Publication 4-pane figure (white background) saved as PNG.
C = palette('light');
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 1000]);
% A dark MATLAB desktop theme would otherwise give the exported axes a
% dark background and low-contrast text.
try
    theme(fig, 'light');
catch
    % releases without figure themes are light already
end
tl = tiledlayout(fig, 4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
tms = 1e3 * r.time;
if isnan(s.clearMs)
    sub = sprintf('%s  |  %s', s.state, s.adjacentText);
else
    sub = sprintf('Cleared in %.0f ms (%.1f cycles) by %s  |  %s', s.clearMs, s.clearMs / (1e3 / 60), ...
        ['relay ' s.trippedLat], s.adjacentText);
end
title(tl, {sc.description, sub}, 'FontSize', 12);

ax = nexttile(tl);
hold(ax, 'on');
for p = 1:3
    plot(ax, tms, r.I_650_physical(:, p), 'Color', C.phase(p, :), 'LineWidth', 0.9, ...
        'DisplayName', sprintf('Phase %c', 'A' + p - 1));
end
ylabel(ax, 'I_{650} (A)');
title(ax, 'Substation feeder current', 'FontWeight', 'normal');
decorate(ax, s, C);

ax = nexttile(tl);
hold(ax, 'on');
dI = r.(['dI_' s.eventLat]);
dO = r.(['dI_' s.otherLat]);
plot(ax, tms, dO, 'Color', [0.75 0.75 0.75], 'LineWidth', 0.8, 'HandleVisibility', 'off');
for p = 1:3
    plot(ax, tms, dI(:, p), 'Color', C.phase(p, :), 'LineWidth', 1, ...
        'DisplayName', sprintf('Lateral %s phase %c', s.eventLat, 'A' + p - 1));
end
plot(ax, NaN, NaN, 'Color', [0.75 0.75 0.75], 'DisplayName', sprintf('Lateral %s (all phases)', s.otherLat));
ylabel(ax, '\DeltaI (A)');
title(ax, 'Digital-twin residual \DeltaI = I_{physical} - I_{twin}', 'FontWeight', 'normal');
decorate(ax, s, C);

ax = nexttile(tl);
hold(ax, 'on');
stairs(ax, tms, r.trip_633, 'Color', C.cyan, 'LineWidth', 1.8, 'DisplayName', 'Relay 633 trip');
stairs(ax, tms, r.trip_675 * 0.97, 'Color', C.magenta, 'LineWidth', 1.8, 'DisplayName', 'Relay 675 trip');
ylim(ax, [-0.1 1.2]);
ax.YTick = [0 1];
ylabel(ax, 'Trip');
title(ax, 'Relay trip commands (2-of-3 window vote)', 'FontWeight', 'normal');
decorate(ax, s, C);

ax = nexttile(tl);
hold(ax, 'on');
env = @(I) cycleRmsMaxPhase(I, r.time);
plot(ax, tms, env(r.I_633_physical), 'Color', C.cyan, 'LineWidth', 1.8, 'DisplayName', 'Lateral 632-633');
plot(ax, tms, env(r.I_675_physical), 'Color', C.magenta, 'LineWidth', 1.8, 'DisplayName', 'Lateral 692-675');
ylabel(ax, 'RMS (A)');
xlabel(ax, 'Time (ms)');
title(ax, sprintf('Lateral head currents (1-cycle RMS, max phase): L633 %.1f \\rightarrow %.1f A, L675 %.1f \\rightarrow %.1f A', ...
    s.preRms.L633, s.endRms.L633, s.preRms.L675, s.endRms.L675), 'FontWeight', 'normal');
decorate(ax, s, C);

exportgraphics(fig, outFile, 'Resolution', 200);
close(fig);
end

function e = cycleRmsMaxPhase(I, t)
% Trailing 1-cycle RMS of each phase, then the largest phase.
n = round(1 / 60 / (t(2) - t(1)));
e = max(sqrt(movmean(I.^2, [n - 1, 0], 1)), [], 2);
end

function decorate(ax, s, C)
grid(ax, 'on');
xlim(ax, [0 300]);
xline(ax, 1e3 * s.tEvent, '--', 'event', 'Color', C.amber, 'LineWidth', 1, 'HandleVisibility', 'off', ...
    'LabelVerticalAlignment', 'bottom');
if ~isnan(s.tTrip)
    xline(ax, 1e3 * s.tTrip, '--', 'trip', 'Color', C.red, 'LineWidth', 1, 'HandleVisibility', 'off', ...
        'LabelVerticalAlignment', 'bottom');
end
legend(ax, 'Location', 'northeastoutside', 'FontSize', 8);
end

%% ======================================================================
function C = palette(mode)
if strcmp(mode, 'dark')
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
else
    C.amber   = [0.85 0.55 0.00];
    C.red     = [0.80 0.12 0.10];
    C.cyan    = [0.00 0.45 0.74];
    C.magenta = [0.62 0.20 0.70];
    C.phase   = [0.80 0.15 0.10; 0.85 0.62 0.00; 0.10 0.35 0.80];
end
end
