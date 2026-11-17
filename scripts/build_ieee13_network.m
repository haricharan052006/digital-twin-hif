%% build_ieee13_network.m
% Phase 2: Programmatically builds the unbalanced 4.16 kV IEEE 13-Bus
% distribution feeder (Simscape Electrical / Specialized Power Systems)
% and produces two model variants:
%   models/ieee13_physical.slx     - feeder + Emanuel Arc HIF fault at Bus 671
%                                    (relocated to Buses 633/675, phases
%                                    A/B/C, by extend_fault_injection.m)
%   models/ieee13_digital_twin.slx - identical feeder, healthy (no fault)
%
% Engineering scope / documented simplifications:
%   - Substation modeled as a Three-Phase Source directly at Bus 650 (per
%     CLAUDE.md); the upstream 115kV/4.16kV substation transformer and the
%     650-632 voltage regulator are omitted for tractability.
%   - Line configs 601-607 use Three-Phase PI Section Line blocks
%     parameterized with SEQUENCE (positive/zero) R, L, C. Positive-
%     sequence R1/X1 and shunt susceptance B1 are derived from the
%     self-impedance/self-susceptance diagonal entries published for the
%     IEEE 13 Node Test Feeder configuration matrices (ohms/mile,
%     micro-Siemens/mile); mutual coupling is neglected and zero-sequence
%     is approximated as 2.5x positive-sequence (standard distribution
%     rule of thumb), with C0 approximated as 0.5x C1. This is a
%     documented engineering approximation, not a certified utility-grade
%     replica, and is appropriate for fault-transient/waveform HIF study.
%   - All line segments are modeled as fully three-phase conductors, even
%     where the real IEEE13 feeder uses single-/two-phase laterals (e.g.
%     645-646, 684-611, 684-652). Phases that carry no load beyond a given
%     point are open-terminated (1 MOhm to ground) at the leaf bus where
%     they stop being used. Per-phase UNBALANCE is preserved faithfully
%     through the standard spot-load table (unequal P/Q per phase, delta
%     legs tied between specific phase pairs) and the single-phase
%     capacitor bank at Bus 611.
%   - Spot loads use the standard table's Y/D connection, phase(s), and
%     P/Q values, realized with Series RLC Load blocks whose LoadType is
%     set to constant-PQ / constant-Z / constant-I to match the published
%     PQ/Z/I load-model column for each bus.
%   - The distributed load specified along line 632-671 in the full IEEE13
%     definition is omitted (documented simplification); only the lumped
%     spot loads are modeled.
%   - Both models are configured with powergui in discrete mode at
%     Ts = 50e-6 s (20 kHz) per CLAUDE.md.
%
% Known benign warning: compiling/updating ieee13_physical.slx (only the
% fault-carrying variant) emits "Matrix is close to singular or badly
% scaled" from powergui's state-space realization (etass/powersolve). This
% comes from mixing the fault branch's diode/snubber impedances (Ohms) with
% the rest of the feeder's much larger open-termination and load impedances
% in one combined linear system, and was confirmed NOT to affect the actual
% discrete-time simulation: a direct sim() run produced finite, bounded,
% NaN/Inf-free results. Both models still pass a full diagram
% compile/update with no structural (unconnected-port) errors.
%
% Requires: Simscape Electrical / Specialized Power Systems.

scriptDir = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
modelsDir = fullfile(projectRoot, 'models');
if ~exist(modelsDir, 'dir')
    mkdir(modelsDir);
end

arcModelFile = fullfile(modelsDir, 'emanuel_arc_subsystem.slx');
if ~isfile(arcModelFile)
    error('build_ieee13_network:ArcModelMissing', ...
        'models/emanuel_arc_subsystem.slx not found. Run build_emanuel_arc.m first.');
end

%% Locate the Specialized Power Systems library (name varies by release)
libRoot = '';
for cand = ["sps_lib", "powerlib"]
    try
        load_system(cand);
        libRoot = char(cand);
        break;
    catch
    end
end
if isempty(libRoot)
    error('build_ieee13_network:LibraryNotFound', ...
        ['Specialized Power Systems library not found. ' ...
         'Verify Simscape Electrical is installed.']);
end

%% Load the Emanuel Arc HIF subsystem source model (for copying into the
%  physical twin) without opening a display window.
if bdIsLoaded('emanuel_arc_subsystem')
    close_system('emanuel_arc_subsystem', 0);
end
load_system(arcModelFile);

%% Line configuration data: [R1 (Ohm/mile), X1 (Ohm/mile), B1 (uS/mile)]
% Self-impedance / self-susceptance diagonal entries per the IEEE 13 Node
% Test Feeder configuration matrices (see header notes on approximation).
cfgRaw = containers.Map();
cfgRaw('601') = [0.3465 1.0179 6.2998];
cfgRaw('602') = [0.7526 1.1814 5.6990];
cfgRaw('603') = [1.3294 1.3471 4.7097];
cfgRaw('604') = [1.3228 1.3569 4.6000];
cfgRaw('605') = [1.3292 1.3475 4.7000];
cfgRaw('606') = [0.7982 0.4463 96.0000];
cfgRaw('607') = [1.3425 0.5154 88.0000];

%% Line segment table (name, from-bus, to-bus, length in feet, config)
lineSegs = struct('name', {}, 'from', {}, 'to', {}, 'lengthFt', {}, 'config', {});
lineSegs(end+1) = struct('name', 'Line_650_632', 'from', '650', 'to', '632', 'lengthFt', 2000, 'config', '601');
lineSegs(end+1) = struct('name', 'Line_632_633', 'from', '632', 'to', '633', 'lengthFt', 500,  'config', '602');
lineSegs(end+1) = struct('name', 'Line_632_645', 'from', '632', 'to', '645', 'lengthFt', 500,  'config', '603');
lineSegs(end+1) = struct('name', 'Line_645_646', 'from', '645', 'to', '646', 'lengthFt', 300,  'config', '603');
lineSegs(end+1) = struct('name', 'Line_632_671', 'from', '632', 'to', '671', 'lengthFt', 2000, 'config', '601');
lineSegs(end+1) = struct('name', 'Line_671_684', 'from', '671', 'to', '684', 'lengthFt', 300,  'config', '604');
lineSegs(end+1) = struct('name', 'Line_684_611', 'from', '684', 'to', '611', 'lengthFt', 300,  'config', '605');
lineSegs(end+1) = struct('name', 'Line_684_652', 'from', '684', 'to', '652', 'lengthFt', 800,  'config', '607');
lineSegs(end+1) = struct('name', 'Line_671_680', 'from', '671', 'to', '680', 'lengthFt', 1000, 'config', '601');
% Line_692_675 is built separately after the 671-692 tie switch below,
% since bus 692 does not exist until that switch is constructed.
line692_675 = struct('name', 'Line_692_675', 'from', '692', 'to', '675', 'lengthFt', 500, 'config', '606');

%% Build both model variants
buildNetwork(fullfile(modelsDir, 'ieee13_physical.slx'), 'ieee13_physical', true, ...
    libRoot, cfgRaw, lineSegs, line692_675);
buildNetwork(fullfile(modelsDir, 'ieee13_digital_twin.slx'), 'ieee13_digital_twin', false, ...
    libRoot, cfgRaw, lineSegs, line692_675);

close_system('emanuel_arc_subsystem', 0);

fprintf('IEEE 13-bus physical model saved to:     %s\n', fullfile(modelsDir, 'ieee13_physical.slx'));
fprintf('IEEE 13-bus digital twin model saved to: %s\n', fullfile(modelsDir, 'ieee13_digital_twin.slx'));

%% ======================================================================
function buildNetwork(modelFile, modelName, includeFault, libRoot, cfgRaw, lineSegs, line692_675)
% Builds one IEEE13-based feeder variant and saves it to modelFile.

if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
new_system(modelName);
open_system(modelName);

sourceBlk       = [libRoot '/Sources/Three-Phase Source'];
piLineBlk       = [libRoot '/Power Grid Elements/Three-Phase PI Section Line'];
xfmrBlk         = [libRoot '/Power Grid Elements/Three-Phase Transformer (Two Windings)'];
tieBreakerBlk   = [libRoot '/Power Grid Elements/Three-Phase Breaker'];
faultBreakerBlk = [libRoot '/Power Grid Elements/Breaker'];
rlcLoadBlk      = [libRoot '/Passives/Series RLC Load'];
rlcBranchBlk    = [libRoot '/Passives/Series RLC Branch'];
groundBlk       = [libRoot '/Utilities/Ground'];
powerguiBlk     = [libRoot '/powergui'];

%% Substation source at Bus 650 (4.16 kV, swing bus)
add_block(sourceBlk, [modelName '/Src_650'], 'Position', nextPos());
% 'SpecifyImpedance' is the "Specify short-circuit level parameters"
% checkbox, NOT "use R/L". Left 'on', the block ignores Resistance /
% Inductance and derives its impedance from ShortCircuitLevel 100 MVA at
% the library-default BaseVoltage 25 kV: Z = 25e3^2/100e6 = 6.25 Ohm, which
% sagged the whole loaded feeder to ~0.5 pu. 'off' uses R = 0.1 Ohm,
% L = 1 mH (|Z| ~ 0.39 Ohm) as intended.
set_param([modelName '/Src_650'], 'Voltage', '4160', 'PhaseAngle', '0', ...
    'Frequency', '60', 'NonIdealSource', 'on', 'SpecifyImpedance', 'off', ...
    'Resistance', '0.1', 'Inductance', '0.001');

busPorts = containers.Map();
busPorts('650') = {'Src_650/RConn1', 'Src_650/RConn2', 'Src_650/RConn3'};

%% Feeder line segments (all modeled as full three-phase PI sections)
for i = 1:numel(lineSegs)
    busPorts = addLineSeg(modelName, piLineBlk, cfgRaw, busPorts, lineSegs(i));
end

%% In-line step-down transformer 633-634 (4.16kV Delta / 0.48kV Grounded-Wye, 500 kVA)
xfmr = [modelName '/XFM_633_634'];
add_block(xfmrBlk, xfmr, 'Position', nextPos());
set_param(xfmr, 'Winding1Connection', 'Delta (D1)', 'Winding2Connection', 'Yg', ...
    'UNITS', 'pu', 'NominalPower', mat2str([500e3 60]), ...
    'Winding1', mat2str([4160 0.0055 0.01]), 'Winding2', mat2str([480 0.0055 0.01]));
p633 = busPorts('633');
for k = 1:3
    add_line(modelName, p633{k}, sprintf('XFM_633_634/LConn%d', k), 'autorouting', 'on');
end
busPorts('634') = {'XFM_633_634/RConn1', 'XFM_633_634/RConn2', 'XFM_633_634/RConn3'};

%% 671-692 normally-closed tie switch (zero-impedance jumper)
tie = [modelName '/Tie_671_692'];
add_block(tieBreakerBlk, tie, 'Position', nextPos());
% The Three-Phase Breaker ships with SwitchTimes [1/60 5/60]: left at that
% default the tie opens at 16.7 ms and recloses at 83.3 ms, islanding Buses
% 692/675 for most of every run. A far-future time keeps it closed (an
% empty SwitchTimes errors in the block's mask initialization).
set_param(tie, 'InitialState', 'closed', 'External', 'off', 'SwitchTimes', '[1e6]');
p671 = busPorts('671');
for k = 1:3
    add_line(modelName, p671{k}, sprintf('Tie_671_692/LConn%d', k), 'autorouting', 'on');
end
busPorts('692') = {'Tie_671_692/RConn1', 'Tie_671_692/RConn2', 'Tie_671_692/RConn3'};

%% Line 692-675 (built after the tie switch establishes Bus 692)
busPorts = addLineSeg(modelName, piLineBlk, cfgRaw, busPorts, line692_675);

%% Spot loads (standard IEEE13 table: bus, connection, phase(s), P/Q, type)
% 634  Y-PQ  A:160kW/110kVAr  B:120kW/90kVAr  C:120kW/90kVAr
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '634', 1, 'L634A', 160e3, 110e3, 'constant PQ');
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '634', 2, 'L634B', 120e3, 90e3,  'constant PQ');
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '634', 3, 'L634C', 120e3, 90e3,  'constant PQ');
% Bus 634 is the 0.48 kV secondary of XFM_633_634: rate its loads at the
% 277 V phase-to-neutral voltage, not tapYLoad's 4.16 kV-system 2400 V
% (at 2400 V nominal they drew only (277/2400)^2 ~ 1.3% of rated power).
for ld = {'L634A', 'L634B', 'L634C'}
    set_param([modelName '/' ld{1}], 'NominalVoltage', '480/sqrt(3)');
end
% 645  Y-PQ  B:170kW/125kVAr
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '645', 2, 'L645B', 170e3, 125e3, 'constant PQ');
% 646  D-Z   BC leg: 230kW/132kVAr
busPorts = tapDeltaLoad(modelName, rlcLoadBlk, busPorts, '646', 2, 3, 'L646BC', 230e3, 132e3, 'constant Z');
% 652  Y-Z   A:128kW/86kVAr
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '652', 1, 'L652A', 128e3, 86e3, 'constant Z');
% 671  D-PQ  all three legs (AB,BC,CA): 385kW/220kVAr each
busPorts = tapDeltaLoad(modelName, rlcLoadBlk, busPorts, '671', 1, 2, 'L671AB', 385e3, 220e3, 'constant PQ');
busPorts = tapDeltaLoad(modelName, rlcLoadBlk, busPorts, '671', 2, 3, 'L671BC', 385e3, 220e3, 'constant PQ');
busPorts = tapDeltaLoad(modelName, rlcLoadBlk, busPorts, '671', 3, 1, 'L671CA', 385e3, 220e3, 'constant PQ');
% 675  Y-PQ  A:485kW/190kVAr  B:68kW/60kVAr  C:290kW/212kVAr
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '675', 1, 'L675A', 485e3, 190e3, 'constant PQ');
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '675', 2, 'L675B', 68e3,  60e3,  'constant PQ');
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '675', 3, 'L675C', 290e3, 212e3, 'constant PQ');
% 692  D-I   CA leg: 170kW/151kVAr
busPorts = tapDeltaLoad(modelName, rlcLoadBlk, busPorts, '692', 3, 1, 'L692CA', 170e3, 151e3, 'constant I');
% 611  Y-I   C:170kW/80kVAr
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '611', 3, 'L611C', 170e3, 80e3, 'constant I');

%% Shunt capacitor banks
% 675: 200 kVAr per phase (Y, all three phases)
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '675', 1, 'Cap675A', 0, -200e3, 'constant Z');
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '675', 2, 'Cap675B', 0, -200e3, 'constant Z');
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '675', 3, 'Cap675C', 0, -200e3, 'constant Z');
% 611: 100 kVAr, phase C only
busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, '611', 3, 'Cap611C', 0, -100e3, 'constant Z');

%% Open-terminate phases that carry no load beyond their leaf bus
% (documented three-phase-conductor simplification; see header notes)
busPorts = openTerminate(modelName, rlcBranchBlk, groundBlk, busPorts, '680', 1, 'Open680A');
busPorts = openTerminate(modelName, rlcBranchBlk, groundBlk, busPorts, '680', 2, 'Open680B');
busPorts = openTerminate(modelName, rlcBranchBlk, groundBlk, busPorts, '680', 3, 'Open680C');
busPorts = openTerminate(modelName, rlcBranchBlk, groundBlk, busPorts, '646', 1, 'Open646A');
busPorts = openTerminate(modelName, rlcBranchBlk, groundBlk, busPorts, '652', 2, 'Open652B');
busPorts = openTerminate(modelName, rlcBranchBlk, groundBlk, busPorts, '652', 3, 'Open652C');
busPorts = openTerminate(modelName, rlcBranchBlk, groundBlk, busPorts, '611', 1, 'Open611A');
busPorts = openTerminate(modelName, rlcBranchBlk, groundBlk, busPorts, '611', 2, 'Open611B');

%% Emanuel Arc HIF fault, integrated via a breaker switch at Bus 671 (phase A)
if includeFault
    fltBreaker = [modelName '/FaultBreaker_671'];
    add_block(faultBreakerBlk, fltBreaker, 'Position', nextPos());
    % 'External' MUST be turned off. The SPS Breaker block ships with
    % external control of switching times ENABLED by default, in which case
    % SwitchingTimes is ignored and the breaker state is taken from a
    % control inport instead. Simulink does not flag that inport as an
    % error here, so the breaker would silently stay open for the whole run
    % and the HIF would never energize (only ~3.4 mA of snubber leakage
    % reaches the arc branch).
    set_param(fltBreaker, 'External', 'off', 'InitialState', '0', ...
        'SwitchingTimes', '[0.05]');

    add_block('emanuel_arc_subsystem/Emanuel_Arc_Fault', [modelName '/Emanuel_Arc_Fault'], 'Position', nextPos());

    p671fault = busPorts('671');
    add_line(modelName, p671fault{1}, 'FaultBreaker_671/LConn1', 'autorouting', 'on');
    add_line(modelName, 'FaultBreaker_671/RConn1', 'Emanuel_Arc_Fault/LConn1', 'autorouting', 'on');
    add_block(groundBlk, [modelName '/FaultGnd'], 'Position', nextPos());
    add_line(modelName, 'Emanuel_Arc_Fault/LConn2', 'FaultGnd/LConn1', 'autorouting', 'on');

    % Bind the arc breakdown parameters into THIS model's Model Workspace
    % so the fault subsystem resolves Vp_arc/Vn_arc/Rp_arc/Rn_arc
    % standalone (see build_emanuel_arc.m Phase 1 fix).
    mdlWks = get_param(modelName, 'ModelWorkspace');
    assignin(mdlWks, 'Vp_arc', 1500);
    assignin(mdlWks, 'Vn_arc', 2000);
    assignin(mdlWks, 'Rp_arc', 200);
    assignin(mdlWks, 'Rn_arc', 300);
end

%% powergui: discrete mode, Ts = 50e-6 s (20 kHz) per CLAUDE.md
add_block(powerguiBlk, [modelName '/powergui'], 'Position', nextPos());
set_param([modelName '/powergui'], 'SimulationMode', 'Discrete', 'SampleTime', '50e-6');

%% Layout + save
Simulink.BlockDiagram.arrangeSystem(modelName);
save_system(modelName, modelFile);
close_system(modelName, 0);

end

%% ======================================================================
function busPorts = addLineSeg(modelName, piLineBlk, cfgRaw, busPorts, seg)
% Adds one Three-Phase PI Section Line segment and registers its
% far-end (to-bus) ports in busPorts.
raw = cfgRaw(seg.config);
seq = seqParamsFromMileData(raw(1), raw(2), raw(3));
blk = [modelName '/' seg.name];
add_block(piLineBlk, blk, 'Position', nextPos());
lengthKm = seg.lengthFt * 0.0003048;
set_param(blk, 'Length', sprintf('%.6f', lengthKm), 'Frequency', '60', ...
    'Resistances', mat2str(seq.R), 'Inductances', mat2str(seq.L), ...
    'Capacitances', mat2str(seq.C));
fromPorts = busPorts(seg.from);
for k = 1:3
    add_line(modelName, fromPorts{k}, sprintf('%s/LConn%d', seg.name, k), 'autorouting', 'on');
end
busPorts(seg.to) = {sprintf('%s/RConn1', seg.name), sprintf('%s/RConn2', seg.name), sprintf('%s/RConn3', seg.name)};
end

%% ======================================================================
function pos = nextPos()
% Simple incrementing grid position generator; exact layout is cleaned up
% by Simulink.BlockDiagram.arrangeSystem before saving.
persistent n
if isempty(n)
    n = 0;
end
n = n + 1;
col = mod(n - 1, 12);
row = floor((n - 1) / 12);
x = 50 + col * 90;
y = 50 + row * 90;
pos = [x, y, x + 45, y + 35];
end

%% ======================================================================
function seq = seqParamsFromMileData(R1_mile, X1_mile, B1_mile_uS)
% Converts mile-based self-impedance/self-susceptance data to the
% positive/zero-sequence [.,.] R (Ohm/km), L (H/km), C (F/km) vectors
% expected by the Three-Phase PI Section Line block. See build script
% header for the zero-sequence and shunt-capacitance approximations.
MILE_KM = 1.609344;
w = 2 * pi * 60;

R1 = R1_mile / MILE_KM;
X1 = X1_mile / MILE_KM;
L1 = X1 / w;
B1_km = B1_mile_uS / MILE_KM;
C1 = (B1_km * 1e-6) / w;

R0 = 2.5 * R1;
X0 = 2.5 * X1;
L0 = X0 / w;
C0 = 0.5 * C1;

seq.R = [R1 R0];
seq.L = [L1 L0];
seq.C = [C1 C0];
end

%% ======================================================================
function busPorts = tapYLoad(modelName, rlcLoadBlk, groundBlk, busPorts, bus, phaseIdx, name, Pw, Qvar, loadType)
% Wye-connected (phase-to-neutral) load or capacitor tap.
blk = [modelName '/' name];
add_block(rlcLoadBlk, blk, 'Position', nextPos());
if Qvar >= 0
    indPower = Qvar; capPower = 0;
else
    indPower = 0; capPower = -Qvar;
end
set_param(blk, 'NominalVoltage', '2400', 'NominalFrequency', '60', 'LoadType', loadType, ...
    'ActivePower', num2str(Pw), 'InductivePower', num2str(indPower), 'CapacitivePower', num2str(capPower));

ports = busPorts(bus);
add_line(modelName, ports{phaseIdx}, [name '/LConn1'], 'autorouting', 'on');

gname = [name '_Gnd'];
add_block(groundBlk, [modelName '/' gname], 'Position', nextPos());
add_line(modelName, [name '/RConn1'], [gname '/LConn1'], 'autorouting', 'on');
end

%% ======================================================================
function busPorts = tapDeltaLoad(modelName, rlcLoadBlk, busPorts, bus, phaseIdx1, phaseIdx2, name, Pw, Qvar, loadType)
% Delta-connected (phase-to-phase) load leg.
blk = [modelName '/' name];
add_block(rlcLoadBlk, blk, 'Position', nextPos());
if Qvar >= 0
    indPower = Qvar; capPower = 0;
else
    indPower = 0; capPower = -Qvar;
end
set_param(blk, 'NominalVoltage', '4160', 'NominalFrequency', '60', 'LoadType', loadType, ...
    'ActivePower', num2str(Pw), 'InductivePower', num2str(indPower), 'CapacitivePower', num2str(capPower));

ports = busPorts(bus);
add_line(modelName, ports{phaseIdx1}, [name '/LConn1'], 'autorouting', 'on');
add_line(modelName, ports{phaseIdx2}, [name '/RConn1'], 'autorouting', 'on');
end

%% ======================================================================
function busPorts = openTerminate(modelName, rlcBranchBlk, groundBlk, busPorts, bus, phaseIdx, name)
% Open-circuit termination (1 MOhm to ground) for a phase conductor that
% carries no load beyond this leaf bus. Chosen large enough to be an
% effective open circuit relative to feeder impedances, but not so large
% (e.g. 1e9) that it badly conditions the network admittance matrix.
blk = [modelName '/' name];
add_block(rlcBranchBlk, blk, 'Position', nextPos());
set_param(blk, 'BranchType', 'R', 'Resistance', '1e6');

ports = busPorts(bus);
add_line(modelName, ports{phaseIdx}, [name '/LConn1'], 'autorouting', 'on');

gname = [name '_Gnd'];
add_block(groundBlk, [modelName '/' gname], 'Position', nextPos());
add_line(modelName, [name '/RConn1'], [gname '/LConn1'], 'autorouting', 'on');
end
