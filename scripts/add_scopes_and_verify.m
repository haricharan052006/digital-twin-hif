%% add_scopes_and_verify.m
% Phase 3: Instruments the IEEE 13-bus HIF models with signal logging /
% Scope / To Workspace sinks, runs a short headless test simulation, and
% renders a 3-panel waveform figure so the fault signature can be inspected
% visually.
%
% What this script instruments (idempotent - safe to re-run):
%   models/ieee13_physical.slx
%       VI_650      Three-Phase V-I Measurement inserted IN SERIES between
%                   Src_650 and Line_650_632 (i.e. the substation feeder
%                   head at Bus 650). Current measurement only.
%       Scope_I650  / ToWs_I650   ->  workspace variable I_650  (3-ph, A)
%       Emanuel_Arc_Fault/Scope_I_arc, /ToWs_I_arc -> variable I_arc (A)
%   models/ieee13_digital_twin.slx
%       VI_650, Scope_I650, ToWs_I650 -> variable I_650  (3-ph, A)
%   models/emanuel_arc_subsystem.slx
%       Emanuel_Arc_Fault/Scope_I_arc, /ToWs_I_arc -> variable I_arc (A)
%
% In every case BOTH mechanisms are applied: the measurement line is marked
% for Simulink Signal Logging (logsout, custom name) AND a To Workspace
% block is attached, so the data survives regardless of how the model is
% later driven. A Scope is attached alongside for interactive viewing.
%
% IMPORTANT - why the arc model is instrumented but not simulated:
%   ieee13_physical.slx contains a COPY of the Emanuel_Arc_Fault subsystem
%   (LinkStatus = 'none'), not a library link, so instrumenting the source
%   model emanuel_arc_subsystem.slx does NOT propagate into the network
%   model. Both are therefore instrumented independently. However,
%   emanuel_arc_subsystem.slx is not simulated on its own: at its top level
%   the subsystem's 'In'/'Out' physical Connection Ports are unterminated,
%   so it cannot compile standalone and would carry no arc current anyway.
%   The I_arc trace plotted in Panel 3 is captured from the energized arc
%   inside ieee13_physical.slx, which is the only place the arc is driven.
%
% Arc-polarity repair: this script also corrects the Emanuel arc's Vp source
%   polarity (see ensureArcPolarity). As built, branch P's breakdown
%   threshold was inverted to -Vp_arc, so it conducted on ~94% of every cycle
%   and clamped the fault node hard enough to starve the negative branch,
%   producing a unipolar I_arc instead of the asymmetric bipolar arcing
%   signature the Emanuel model is supposed to generate. That would have
%   silently corrupted every downstream DWT energy / skewness / kurtosis
%   feature. build_emanuel_arc.m has been fixed; the repair here covers the
%   already-built models, including the standalone COPY of the subsystem
%   embedded in ieee13_physical.slx.
%
% Fault-breaker repair: this script also re-arms FaultBreaker_671 in
%   ieee13_physical.slx (see ensureFaultBreakerArmed). The SPS Breaker block
%   defaults to external control of switching times, which silently overrode
%   the [0.05] switching time set at build time and held the breaker open for
%   the whole run - the arc branch only ever saw ~3.4 mA of snubber leakage,
%   so there was no fault to observe. build_ieee13_network.m has been fixed to
%   set External='off' at build time; the repair here keeps already-built
%   models usable without a full rebuild.
%
% Solver note: both network models shipped on a Variable-step solver, which
% produces non-uniform and mutually mis-aligned time vectors - unusable for
% a sample-by-sample residual. Because powergui is already Discrete at
% Ts = 50e-6 s, this script pins both models to Fixed-step / discrete at the
% same Ts (persisted to the .slx) so the physical and twin runs land on an
% identical 20 kHz grid. The residual is nevertheless computed on an
% explicit common grid via interpolation, so it stays correct even if the
% solver later changes or falls back.
%
% Outputs:
%   data/waveform_check.png   3-panel comparison figure
%
% Requires: Simulink, Simscape Electrical (Specialized Power Systems).

%% ---------------------------------------------------------------- setup
scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
modelsDir   = fullfile(projectRoot, 'models');
dataDir     = fullfile(projectRoot, 'data');
if ~exist(dataDir, 'dir')
    mkdir(dataDir);
end
addpath(modelsDir);

TS_STR  = '50e-6';      % powergui / solver sample time, 20 kHz per CLAUDE.md
TS      = 50e-6;
T_STOP  = 0.2;          % headless test run length (s)
T_FAULT = 0.05;         % FaultBreaker_671 switching time set in build script

physModel = 'ieee13_physical';
twinModel = 'ieee13_digital_twin';
arcModel  = 'emanuel_arc_subsystem';

for f = {[physModel '.slx'], [twinModel '.slx'], [arcModel '.slx']}
    if ~isfile(fullfile(modelsDir, f{1}))
        error('add_scopes_and_verify:ModelMissing', ...
            'models/%s not found. Run build_emanuel_arc.m and build_ieee13_network.m first.', f{1});
    end
end

libRoot = locateSpsLibrary();
viBlk   = [libRoot '/Sensors and Measurements/Three-Phase V-I Measurement'];

%% -------------------------------------------- 1. open + instrument models
fprintf('=== Instrumenting models ===\n');

% --- Emanuel arc source model: log I_arc inside the reusable subsystem ---
loadModel(arcModel, modelsDir);
instrumentArcSubsystem([arcModel '/Emanuel_Arc_Fault']);
ensureArcPolarity([arcModel '/Emanuel_Arc_Fault']);
save_system(arcModel);
fprintf('  %-24s I_arc logged (source subsystem; not simulated standalone)\n', [arcModel '.slx']);

% --- Physical twin: substation current at Bus 650 + energized arc current ---
loadModel(physModel, modelsDir);
insertSubstationMeasurement(physModel, viBlk);
instrumentArcSubsystem([physModel '/Emanuel_Arc_Fault']);
ensureArcPolarity([physModel '/Emanuel_Arc_Fault']);
ensureFaultBreakerArmed(physModel, T_FAULT);
configureSolver(physModel, TS_STR);
save_system(physModel);
fprintf('  %-24s I_650 + I_arc logged\n', [physModel '.slx']);

% --- Digital twin: substation current at Bus 650 (healthy reference) ---
loadModel(twinModel, modelsDir);
insertSubstationMeasurement(twinModel, viBlk);
configureSolver(twinModel, TS_STR);
save_system(twinModel);
fprintf('  %-24s I_650 logged\n', [twinModel '.slx']);

%% ------------------------------------------------ 2. headless simulation
fprintf('\n=== Simulating %.3f s headlessly ===\n', T_STOP);
outPhys = runSim(physModel, T_STOP);
fprintf('  %s done\n', physModel);
outTwin = runSim(twinModel, T_STOP);
fprintf('  %s done\n', twinModel);

%% -------------------------------------------------- 3. extract + residual
[tPhys, iPhys] = fetchSignal(outPhys, 'I_650');
[tTwin, iTwin] = fetchSignal(outTwin, 'I_650');
[tArc,  iArc ] = fetchSignal(outPhys, 'I_arc');

% Common uniform 20 kHz grid; both runs are resampled onto it before the
% subtraction so the residual is never corrupted by mis-aligned solver steps.
tGrid = (0:TS:T_STOP)';
iP = resampleOnto(tPhys, iPhys, tGrid);
iT = resampleOnto(tTwin, iTwin, tGrid);
iA = resampleOnto(tArc,  iArc,  tGrid);
dI = iP - iT;                       % residual current  dI = I_phys - I_twin

pre  = tGrid <  T_FAULT;
post = tGrid >= T_FAULT;
fprintf('\n=== Residual summary (dI = I_physical - I_twin) ===\n');
fprintf('  %-6s %14s %14s %14s\n', 'phase', 'RMS pre (A)', 'RMS post (A)', 'peak post (A)');
for k = 1:3
    fprintf('  %-6s %14.4f %14.4f %14.4f\n', char('A'+k-1), ...
        rms(dI(pre, k)), rms(dI(post, k)), max(abs(dI(post, k))));
end
fprintf('  Arc current I_arc: peak %.4f A, RMS(post-inception) %.4f A\n', ...
    max(abs(iA)), rms(iA(post)));

%% --------------------------------------------------------- 4. the figure
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [80 80 1150 950]);
tl  = tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
phaseCol = [0.85 0.16 0.16; 0.13 0.47 0.79; 0.20 0.60 0.25];   % A, B, C
phaseTag = {'A', 'B', 'C'};

% -- Panel 1: substation current, physical vs digital twin ---------------
ax1 = nexttile(tl); hold(ax1, 'on'); grid(ax1, 'on'); box(ax1, 'on');
for k = 1:3
    plot(ax1, tGrid, iP(:, k), '-', 'Color', phaseCol(k, :), 'LineWidth', 1.2, ...
        'DisplayName', sprintf('Physical I_%s', phaseTag{k}));
end
for k = 1:3
    plot(ax1, tGrid, iT(:, k), '--', 'Color', min(phaseCol(k, :) + 0.42, 1), ...
        'LineWidth', 1.1, 'DisplayName', sprintf('Twin I_%s', phaseTag{k}));
end
markFault(ax1, T_FAULT);
ylabel(ax1, 'Current (A)');
title(ax1, 'Panel 1 — Substation 3-Phase Current at Bus 650: Physical vs Digital Twin');
legend(ax1, 'Location', 'northeast', 'NumColumns', 2, 'FontSize', 8);
headroom(ax1, 0.38);

% -- Panel 2: residual current -------------------------------------------
ax2 = nexttile(tl); hold(ax2, 'on'); grid(ax2, 'on'); box(ax2, 'on');
for k = 1:3
    plot(ax2, tGrid, dI(:, k), '-', 'Color', phaseCol(k, :), 'LineWidth', 1.2, ...
        'DisplayName', sprintf('\\DeltaI_%s', phaseTag{k}));
end
markFault(ax2, T_FAULT);
ylabel(ax2, 'Residual current (A)');
title(ax2, 'Panel 2 — Residual \DeltaI = I_{physical} - I_{twin}  (digital-twin differential signature)');
legend(ax2, 'Location', 'northeast', 'NumColumns', 3, 'FontSize', 8);
headroom(ax2, 0.30);

% -- Panel 3: raw Emanuel arc current ------------------------------------
ax3 = nexttile(tl); hold(ax3, 'on'); grid(ax3, 'on'); box(ax3, 'on');
plot(ax3, tGrid, iA, '-', 'Color', [0.42 0.16 0.62], 'LineWidth', 1.2, ...
    'DisplayName', 'I_{arc}');
markFault(ax3, T_FAULT);
xlabel(ax3, 'Time (s)');
ylabel(ax3, 'Arc current (A)');
title(ax3, 'Panel 3 — Raw Emanuel Arc Fault Current I_{arc} (Bus 671, phase A)');
legend(ax3, 'Location', 'northeast', 'FontSize', 8);
headroom(ax3, 0.28);

linkaxes([ax1 ax2 ax3], 'x');
xlim(ax1, [0 T_STOP]);
title(tl, sprintf('IEEE 13-Bus HIF Digital Twin — waveform check (f_s = 20 kHz, %.2f s run)', T_STOP), ...
    'FontWeight', 'bold');

outPng = fullfile(dataDir, 'waveform_check.png');
exportgraphics(fig, outPng, 'Resolution', 200);
close(fig);
fprintf('\nFigure saved to: %s\n', outPng);

%% ======================================================================
function libRoot = locateSpsLibrary()
% Specialized Power Systems library name varies by release.
for cand = ["sps_lib", "powerlib"]
    try
        load_system(cand);
        libRoot = char(cand);
        return;
    catch
    end
end
error('add_scopes_and_verify:LibraryNotFound', ...
    'Specialized Power Systems library not found. Verify Simscape Electrical is installed.');
end

%% ======================================================================
function loadModel(modelName, modelsDir)
% Loads a model from the models/ folder without opening a display window
% (this script is intended to run headlessly under matlab -batch).
if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
load_system(fullfile(modelsDir, [modelName '.slx']));
end

%% ======================================================================
function insertSubstationMeasurement(modelName, viBlk)
% Inserts a Three-Phase V-I Measurement block in series between the
% substation source Src_650 and the first feeder segment Line_650_632, then
% attaches a Scope + To Workspace sink and enables signal logging on the
% resulting Iabc signal. Idempotent.

viPath = [modelName '/VI_650'];

if getSimulinkBlockHandle(viPath) <= 0
    % Break the three existing Src_650 -> Line_650_632 physical connections
    % using line handles (robust against port-designator syntax differences).
    lh = get_param([modelName '/Src_650'], 'LineHandles');
    for k = 1:numel(lh.RConn)
        if lh.RConn(k) > 0
            delete_line(lh.RConn(k));
        end
    end

    add_block(viBlk, viPath, 'Position', freeStrip(modelName, 0));
    % Current only - voltage measurement is not needed for this check.
    set_param(viPath, 'VoltageMeasurement', 'no', 'CurrentMeasurement', 'yes');
    trySet(viPath, 'Ipu', 'off');    % report SI amperes, not per-unit

    for k = 1:3
        add_line(modelName, sprintf('Src_650/RConn%d', k), ...
            sprintf('VI_650/LConn%d', k), 'autorouting', 'on');
        add_line(modelName, sprintf('VI_650/RConn%d', k), ...
            sprintf('Line_650_632/LConn%d', k), 'autorouting', 'on');
    end
end

ph = get_param(viPath, 'PortHandles');
if numel(ph.Outport) ~= 1
    error('add_scopes_and_verify:UnexpectedViPorts', ...
        ['VI_650 exposes %d signal outports; expected exactly 1 (Iabc) after ' ...
         'disabling voltage measurement.'], numel(ph.Outport));
end

attachSinks(modelName, 'VI_650', 'I_650', 1);
end

%% ======================================================================
function instrumentArcSubsystem(arcPath)
% Attaches Scope + To Workspace sinks and signal logging to the I_arc
% Current Measurement block inside an Emanuel_Arc_Fault subsystem. Works
% for both the standalone source model and the copy embedded in
% ieee13_physical.slx. Idempotent.

if getSimulinkBlockHandle(arcPath) <= 0
    error('add_scopes_and_verify:ArcSubsystemMissing', ...
        'Subsystem %s not found.', arcPath);
end

% The build script parked the measurement output on a Terminator; drop that
% stub so the signal feeds real sinks instead.
termPath = [arcPath '/Term_I_arc'];
if getSimulinkBlockHandle(termPath) > 0
    try
        delete_line(arcPath, 'I_arc/1', 'Term_I_arc/1');
    catch
    end
    delete_block(termPath);
end

attachSinks(arcPath, 'I_arc', 'I_arc', 1);
end

%% ======================================================================
function attachSinks(sysPath, srcBlockName, varName, portIdx)
% Branches output port portIdx of srcBlockName into a Scope and a To
% Workspace block, names the signal, and turns on Simulink signal logging
% for it. Idempotent: existing sinks are left in place.

scopeName = ['Scope_' varName];
towsName  = ['ToWs_'  varName];
srcSpec   = sprintf('%s/%d', srcBlockName, portIdx);

if getSimulinkBlockHandle([sysPath '/' scopeName]) <= 0
    add_block('simulink/Sinks/Scope', [sysPath '/' scopeName], ...
        'Position', freeStrip(sysPath, 1));
    add_line(sysPath, srcSpec, [scopeName '/1'], 'autorouting', 'on');
end

if getSimulinkBlockHandle([sysPath '/' towsName]) <= 0
    add_block('simulink/Sinks/To Workspace', [sysPath '/' towsName], ...
        'Position', freeStrip(sysPath, 2));
    set_param([sysPath '/' towsName], 'VariableName', varName);
    trySet([sysPath '/' towsName], 'SaveFormat',    'Timeseries');
    trySet([sysPath '/' towsName], 'MaxDataPoints', 'inf');
    trySet([sysPath '/' towsName], 'SampleTime',    '-1');
    add_line(sysPath, srcSpec, [towsName '/1'], 'autorouting', 'on');
end

% Name the signal and mark it for logging into logsout.
ph = get_param([sysPath '/' srcBlockName], 'PortHandles');
p  = ph.Outport(portIdx);
lineH = get_param(p, 'Line');
if lineH > 0
    trySetH(lineH, 'Name', varName);
end
trySetH(p, 'DataLogging',         'on');
trySetH(p, 'DataLoggingNameMode', 'Custom');
trySetH(p, 'DataLoggingName',     varName);
end

%% ======================================================================
function ensureArcPolarity(arcPath)
% Repairs the Vp source polarity inside an Emanuel_Arc_Fault subsystem.
%
% For the SPS DC Voltage Source, LConn1 is '-' and RConn1 is '+'.
% build_emanuel_arc.m originally fed the Diode_P cathode into Vp/LConn1,
% which inverts the positive branch threshold from +Vp_arc to -Vp_arc. The
% branch then conducts for V_fault > -1500 V instead of V_fault > +1500 V,
% i.e. ~94% of every cycle, collapsing the arc into a near-continuous 200
% Ohm shunt. That also clamps the fault node to about +/-2.1 kV, which
% keeps it above -Vn_arc and so starves the negative branch entirely -
% giving the unipolar I_arc that this check first exposed.
%
% build_emanuel_arc.m now wires this correctly; this repairs already-built
% models (including the standalone COPY embedded in ieee13_physical.slx).
% Idempotent: the rewire is unconditional, so re-running is a no-op.

vp = [arcPath '/Vp'];
if getSimulinkBlockHandle(vp) <= 0
    return;
end

if portPeerIs(vp, 'LConn', 1, 'Diode_P')
    fprintf(['  NOTE: Emanuel arc Vp source was wired with reversed polarity,\n' ...
             '        inverting the positive breakdown threshold to -Vp_arc.\n' ...
             '        Rewiring so branch P conducts only above +Vp_arc.\n']);
end

lh = get_param(vp, 'LineHandles');
for fld = ["LConn", "RConn"]
    H = lh.(char(fld));
    for k = 1:numel(H)
        if H(k) > 0
            delete_line(H(k));
        end
    end
end
add_line(arcPath, 'Diode_P/RConn1', 'Vp/RConn1', 'autorouting', 'on');
add_line(arcPath, 'Vp/LConn1',      'Rp/LConn1', 'autorouting', 'on');
end

%% ======================================================================
function tf = portPeerIs(blockPath, portField, idx, peerName)
% True if the line on the given physical port has peerName at either end.
tf = false;
lh = get_param(blockPath, 'LineHandles');
H = lh.(portField);
if idx > numel(H) || H(idx) <= 0
    return;
end
for h = [get_param(H(idx), 'SrcBlockHandle'), get_param(H(idx), 'DstBlockHandle')]
    if h > 0 && strcmp(get_param(h, 'Name'), peerName)
        tf = true;
        return;
    end
end
end

%% ======================================================================
function ensureFaultBreakerArmed(modelName, tFault)
% Repairs the fault breaker so the HIF actually energizes.
%
% The SPS Breaker block defaults to External = 'on' (external control of
% switching times), which makes it ignore SwitchingTimes and read its state
% from a control inport. build_ieee13_network.m originally set only
% InitialState/SwitchingTimes, leaving External on and that inport dangling,
% so FaultBreaker_671 stayed open for the entire run and the arc branch saw
% nothing but ~3.4 mA of 1 MOhm snubber leakage. Simulink does not raise an
% error for this, so it is silent.
%
% build_ieee13_network.m now sets External='off' at build time; this
% function repairs models built before that fix so the verification run is
% valid without forcing a full network rebuild. Idempotent.

blk = [modelName '/FaultBreaker_671'];
if getSimulinkBlockHandle(blk) <= 0
    return;     % healthy digital twin has no fault breaker - nothing to arm
end

if strcmp(get_param(blk, 'External'), 'on')
    fprintf(['  NOTE: FaultBreaker_671 had external control enabled, so its\n' ...
             '        switching times were being ignored and the fault never\n' ...
             '        energized. Repairing to time-based switching at t = %g s.\n'], tFault);
end

set_param(blk, 'External', 'off', 'InitialState', '0', ...
    'SwitchingTimes', sprintf('[%g]', tFault));
end

%% ======================================================================
function configureSolver(modelName, tsStr)
% powergui already discretizes the network at Ts; pin the Simulink solver to
% the same fixed discrete step so the physical and twin runs share an
% identical sample grid (prerequisite for a meaningful residual).
set_param(modelName, 'SolverType', 'Fixed-step', 'Solver', 'FixedStepDiscrete', ...
    'FixedStep', tsStr);
set_param(modelName, 'SignalLogging', 'on', 'SignalLoggingName', 'logsout', ...
    'SaveOutput', 'on', 'SaveFormat', 'Dataset');
end

%% ======================================================================
function out = runSim(modelName, tStop)
% Runs one model headlessly for tStop seconds. If the fixed-step discrete
% solver is rejected (e.g. a continuous state slipped into the model), falls
% back to a stiff variable-step solver and retries once.
simIn = Simulink.SimulationInput(modelName);
simIn = simIn.setModelParameter('StopTime', num2str(tStop));
try
    out = sim(simIn);
catch ME
    warning('add_scopes_and_verify:SolverFallback', ...
        ['Fixed-step discrete run of %s failed (%s). Falling back to ode23tb; ' ...
         'the residual is still computed on a common resampled grid.'], ...
        modelName, ME.message);
    set_param(modelName, 'SolverType', 'Variable-step', 'Solver', 'ode23tb');
    save_system(modelName);
    out = sim(simIn);
end
end

%% ======================================================================
function [t, y] = fetchSignal(simOut, varName)
% Pulls a To Workspace variable out of a SimulationOutput, tolerating the
% several container types To Workspace can emit across releases.
try
    v = simOut.get(varName);
catch
    v = [];
end
if isempty(v)
    error('add_scopes_and_verify:SignalMissing', ...
        ['Simulation produced no variable ''%s''. The To Workspace block may ' ...
         'not have been wired correctly.'], varName);
end

if isa(v, 'timeseries')
    t = v.Time;         y = v.Data;
elseif isa(v, 'Simulink.SimulationData.Signal')
    t = v.Values.Time;  y = v.Values.Data;
elseif isstruct(v) && isfield(v, 'time') && isfield(v, 'signals')
    t = v.time;         y = v.signals.values;
else
    error('add_scopes_and_verify:UnsupportedSignalType', ...
        'Variable ''%s'' has unsupported type %s.', varName, class(v));
end

t = t(:);
y = squeeze(y);
if isvector(y)
    y = y(:);
end
end

%% ======================================================================
function yq = resampleOnto(t, y, tGrid)
% Interpolates y(t) onto tGrid. Duplicate time stamps (emitted at
% discontinuities such as breaker switching) are collapsed to their last
% value first, since interp1 requires strictly unique sample points.
[tu, ia] = unique(t, 'last');
yq = interp1(tu, y(ia, :), tGrid, 'linear', 'extrap');
end

%% ======================================================================
function pos = freeStrip(sysPath, slot)
% Returns a block position in a clear horizontal strip below everything
% already in sysPath, so instrumentation blocks never land on top of the
% existing arranged layout.
blks = find_system(sysPath, 'SearchDepth', 1, 'Type', 'Block');
minX = 50; maxY = 50;
for i = 1:numel(blks)
    if strcmp(blks{i}, sysPath)
        continue;
    end
    p = get_param(blks{i}, 'Position');
    minX = min(minX, p(1));
    maxY = max(maxY, p(4));
end
x = minX + slot * 180;
y = maxY + 100;
pos = [x, y, x + 60, y + 40];
end

%% ======================================================================
function markFault(ax, tFault)
% Vertical marker at fault inception, excluded from the legend.
xl = xline(ax, tFault, 'k:', 'Fault inception', 'LineWidth', 1.2, ...
    'LabelVerticalAlignment', 'bottom', 'LabelHorizontalAlignment', 'right', ...
    'FontSize', 8);
xl.Annotation.LegendInformation.IconDisplayStyle = 'off';
end

%% ======================================================================
function headroom(ax, frac)
% Expands the y-limits upward so the legend does not sit on top of traces.
yl = ylim(ax);
span = yl(2) - yl(1);
if span <= 0
    span = 1;
end
ylim(ax, [yl(1), yl(2) + frac * span]);
end

%% ======================================================================
function trySet(blockPath, param, value)
% set_param that tolerates a parameter being absent/renamed in a release.
try
    set_param(blockPath, param, value);
catch ME
    warning('add_scopes_and_verify:SetParamSkipped', ...
        'Could not set %s on %s (%s).', param, blockPath, ME.message);
end
end

%% ======================================================================
function trySetH(h, param, value)
% Handle-based variant of trySet (for line and port handles).
try
    set_param(h, param, value);
catch
end
end
