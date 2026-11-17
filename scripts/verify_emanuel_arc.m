%% verify_emanuel_arc.m
% Standalone verification of the Emanuel arc HIF subsystem
% (models/emanuel_arc_subsystem.slx / Emanuel_Arc_Fault), isolated from the
% IEEE 13-bus feeder.
%
% Test bench (built in memory, never saved): an ideal 60 Hz AC source at
% 2.4 kV RMS L-N (3394 V peak) drives a copy of Emanuel_Arc_Fault to ground,
% with powergui discrete at Ts = 50e-6 s per CLAUDE.md. The measured arc
% current is compared against the ideal Emanuel characteristic evaluated on
% the measured terminal voltage v:
%     i = (v - Vp)/Rp   for v >  Vp      (positive branch)
%     i = (v + Vn)/Rn   for v < -Vn      (negative branch)
%     i = 0             otherwise
% across parameter points spanning the CLAUDE.md ranges (Vp 500-8000 V,
% Vn 1000-10000 V, Rp/Rn 120-5000 Ohm), including a no-strike case
% (Vp, Vn above the 3394 V source peak).
%
% A second check puts an SPS Breaker in series to confirm the fault-branch
% switching convention: InitialState '0' with an EMPTY SwitchingTimes ('[]')
% is NOT open in discrete mode - the block inverts its initial state when it
% has no switching times - so a dead branch must use a far-future switching
% time (e.g. '[1e6]') instead.
%
% Writes results/emanuel_arc_standalone.png (default-parameter waveform).

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
arcModel    = 'emanuel_arc_subsystem';
arcFile     = fullfile(projectRoot, 'models', [arcModel '.slx']);
resultsDir  = fullfile(projectRoot, 'results');

VRMS = 2400;            % 4.16 kV L-L -> 2.4 kV L-N
PEAK_TOL = 0.03;        % allowed relative peak error on a striking branch
CORR_MIN = 0.99;        % min correlation, measured vs ideal Emanuel current

if bdIsLoaded(arcModel)
    close_system(arcModel, 0);
end
load_system(arcFile);
arcSrc = [arcModel '/Emanuel_Arc_Fault'];

%% 1. Arc characteristic across the CLAUDE.md parameter ranges
cases = [ ...   % Vp     Vn     Rp     Rn
    1500   2000   200    300     % build_emanuel_arc.m defaults
     500   1000   120    120     % range minimum: strongest arc
    2500   3000   1000   2000    % weak arc, near breakdown limit
    8000   10000  5000   5000];  % range maximum: never strikes at 2.4 kV
fprintf('=== Emanuel arc standalone verification (ideal %.0f V RMS source) ===\n', VRMS);
fprintf('%6s %6s %5s %5s | %8s %8s | %8s %8s | %6s %6s | %s\n', 'Vp', 'Vn', 'Rp', 'Rn', ...
    'i+ meas', 'i+ ideal', 'i- meas', 'i- ideal', 'corr', 'leak', 'result');
allPass = true;
for c = 1:size(cases, 1)
    p = num2cell(cases(c, :));
    [Vp, Vn, Rp, Rn] = p{:};
    r = runBench(arcSrc, VRMS, Vp, Vn, Rp, Rn, 'none', '[]');
    ss = r.t >= 0.05;                                 % skip start-up transient
    iIdeal = (r.vX > Vp) .* (r.vX - Vp) / Rp + (r.vX < -Vn) .* (r.vX + Vn) / Rn;
    iMeas = r.iArc(ss);
    iIdeal = iIdeal(ss);
    noConduct = iIdeal == 0;
    leak = max(abs(iMeas(noConduct)));               % current while arc is extinguished
    pkPos = [max(iMeas), max(iIdeal)];
    pkNeg = [min(iMeas), min(iIdeal)];
    if any(iIdeal ~= 0)
        rho = corr(iMeas, iIdeal);
        okPos = pkPos(2) == 0 || abs(pkPos(1) - pkPos(2)) <= PEAK_TOL * pkPos(2);
        okNeg = pkNeg(2) == 0 || abs(pkNeg(1) - pkNeg(2)) <= PEAK_TOL * abs(pkNeg(2));
        pass = okPos && okNeg && rho >= CORR_MIN;
    else
        rho = NaN;
        pass = leak < 1;                             % no strike: only snubber leakage
    end
    allPass = allPass && pass;
    fprintf('%6d %6d %5d %5d | %8.2f %8.2f | %8.2f %8.2f | %6.3f %6.3f | %s\n', ...
        Vp, Vn, Rp, Rn, pkPos(1), pkPos(2), pkNeg(1), pkNeg(2), rho, leak, passStr(pass));
    if c == 1
        rDefault = r;
        defaultParams = cases(c, :);
    end
end

%% 2. Series fault breaker: switching convention
fprintf('\n=== Series fault breaker (defaults Vp=1500 Vn=2000 Rp=200 Rn=300) ===\n');
brkCases = { ...  % InitialState, SwitchingTimes, expected state before / after 0.05 s
    '0', '[1e6]',  'open',   'open'
    '0', '[0.05]', 'open',   'closed'
    '0', '[]',     'closed', 'closed'};             % SPS quirk: inverted, NOT open
for k = 1:size(brkCases, 1)
    r = runBench(arcSrc, VRMS, 1500, 2000, 200, 300, brkCases{k, 1}, brkCases{k, 2});
    before = rms(r.iArc(r.t > 0.01 & r.t < 0.05));
    after  = rms(r.iArc(r.t >= 0.06));
    seen = {stateOf(before), stateOf(after)};
    pass = strcmp(seen{1}, brkCases{k, 3}) && strcmp(seen{2}, brkCases{k, 4});
    note = '';
    if strcmp(brkCases{k, 2}, '[]')
        note = '  <- empty SwitchingTimes inverts InitialState; dead branches must use a far-future time';
    end
    fprintf('InitialState=%s SwitchingTimes=%-7s | I_arc RMS before %.3f A (%s), after %.3f A (%s) | expected %s/%s | %s%s\n', ...
        brkCases{k, 1}, brkCases{k, 2}, before, seen{1}, after, seen{2}, ...
        brkCases{k, 3}, brkCases{k, 4}, passStr(pass), note);
end

%% 3. Waveform figure for the default parameters
fig = figure('Visible', 'off', 'Position', [100 100 900 600]);
tiledlayout(fig, 2, 1);
ax1 = nexttile;
plot(ax1, rDefault.t * 1e3, rDefault.vX / 1e3, 'LineWidth', 1); hold(ax1, 'on');
yline(ax1, defaultParams(1) / 1e3, '--', 'V_p');
yline(ax1, -defaultParams(2) / 1e3, '--', '-V_n');
ylabel(ax1, 'Arc terminal voltage (kV)'); grid(ax1, 'on');
title(ax1, sprintf('Emanuel arc, ideal %.1f kV RMS source (V_p=%d V, V_n=%d V, R_p=%d \\Omega, R_n=%d \\Omega)', ...
    VRMS / 1e3, defaultParams));
ax2 = nexttile;
iIdealDef = (rDefault.vX > defaultParams(1)) .* (rDefault.vX - defaultParams(1)) / defaultParams(3) ...
    + (rDefault.vX < -defaultParams(2)) .* (rDefault.vX + defaultParams(2)) / defaultParams(4);
plot(ax2, rDefault.t * 1e3, rDefault.iArc, 'LineWidth', 1); hold(ax2, 'on');
plot(ax2, rDefault.t * 1e3, iIdealDef, '--', 'LineWidth', 1);
legend(ax2, 'Simulated I_{arc}', 'Ideal Emanuel', 'Location', 'best');
xlabel(ax2, 'Time (ms)'); ylabel(ax2, 'Arc current (A)'); grid(ax2, 'on');
linkaxes([ax1 ax2], 'x');
figFile = fullfile(resultsDir, 'emanuel_arc_standalone.png');
exportgraphics(fig, figFile, 'Resolution', 150);
close(fig);

close_system(arcModel, 0);
fprintf('\nWaveform figure: %s\n', figFile);
if allPass
    fprintf('Arc characteristic: ALL CASES PASS\n');
else
    fprintf('Arc characteristic: FAILURES - see table above\n');
end

%% ======================================================================
function r = runBench(arcSrc, vrms, Vp, Vn, Rp, Rn, brkInit, brkTimes)
% Builds the in-memory test bench, simulates 0.1 s, returns t, terminal
% voltage vX and arc current iArc. brkInit = 'none' omits the breaker.
tb = 'emanuel_arc_testbench';
if bdIsLoaded(tb)
    close_system(tb, 0);
end
new_system(tb);
lib = 'sps_lib';
load_system(lib);
wks = get_param(tb, 'ModelWorkspace');
assignin(wks, 'Vp_arc', Vp);
assignin(wks, 'Vn_arc', Vn);
assignin(wks, 'Rp_arc', Rp);
assignin(wks, 'Rn_arc', Rn);

add_block([lib '/powergui'], [tb '/powergui'], 'Position', [20 20 80 50]);
set_param([tb '/powergui'], 'SimulationMode', 'Discrete', 'SampleTime', '50e-6');
add_block([lib '/Sources/AC Voltage Source'], [tb '/Vs'], 'Position', [60 120 100 160]);
set_param([tb '/Vs'], 'Amplitude', num2str(vrms * sqrt(2)), 'Frequency', '60', 'Phase', '0');
add_block(arcSrc, [tb '/Arc'], 'Position', [300 120 360 180]);
add_block([lib '/Sensors and Measurements/Voltage Measurement'], [tb '/Vm'], 'Position', [240 220 270 250]);
for g = 1:3
    add_block([lib '/Utilities/Ground'], sprintf('%s/G%d', tb, g), 'Position', [100 * g 320 100 * g + 30 340]);
end

srcPh = get_param([tb '/Vs'], 'PortHandles');
srcPorts = [arrayfun(@(k) sprintf('Vs/LConn%d', k), 1:numel(srcPh.LConn), 'UniformOutput', false), ...
            arrayfun(@(k) sprintf('Vs/RConn%d', k), 1:numel(srcPh.RConn), 'UniformOutput', false)];
add_line(tb, srcPorts{2}, 'G1/LConn1', 'autorouting', 'on');
if strcmp(brkInit, 'none')
    node = srcPorts{1};
else
    add_block([lib '/Power Grid Elements/Breaker'], [tb '/Brk'], 'Position', [180 120 220 160]);
    set_param([tb '/Brk'], 'External', 'off', 'InitialState', brkInit, 'SwitchingTimes', brkTimes);
    add_line(tb, srcPorts{1}, 'Brk/LConn1', 'autorouting', 'on');
    node = 'Brk/RConn1';
end
add_line(tb, node, 'Arc/LConn1', 'autorouting', 'on');
add_line(tb, 'Arc/LConn2', 'G2/LConn1', 'autorouting', 'on');
add_line(tb, node, 'Vm/LConn1', 'autorouting', 'on');
add_line(tb, 'Vm/LConn2', 'G3/LConn1', 'autorouting', 'on');
ph = get_param([tb '/Vm'], 'PortHandles');
set_param(ph.Outport(1), 'DataLogging', 'on', 'DataLoggingNameMode', 'Custom', 'DataLoggingName', 'V_arc');

set_param(tb, 'StopTime', '0.1', 'SignalLogging', 'on');
out = sim(tb);
ia = out.logsout.getElement('I_arc').Values;   % logged inside the arc copy
vx = out.logsout.getElement('V_arc').Values;
r.t = ia.Time;
r.iArc = squeeze(ia.Data);
r.vX = interp1(vx.Time, squeeze(vx.Data), r.t);
close_system(tb, 0);
end

function s = stateOf(iRms)
if iRms > 1
    s = 'closed';
else
    s = 'open';
end
end

function s = passStr(tf)
if tf
    s = 'PASS';
else
    s = 'FAIL';
end
end
