%% build_emanuel_arc.m
% Programmatically builds and saves the Emanuel Arc HIF (High Impedance
% Fault) subsystem as models/emanuel_arc_subsystem.slx using the Simulink
% programmatic API (new_system, add_block, set_param, add_line).
%
% Topology: two antiparallel diode branches between external physical
% terminals 'In' and 'Out' (nesl_utility/Connection Port blocks), each
% branch = Diode + DC Voltage Source (arc breakdown voltage) + Resistor
% (arc/soil resistance) in series, per the Emanuel arc model.
%   Branch P (positive half-cycle): In -[Anode]Diode_P[Cathode]- Vp -> Rp -\
%   Branch N (negative half-cycle): In -[Cathode]Diode_N[Anode]- Vn -> Rn -+-> common node -> Current Measurement -> Out
% Rp and Rn join at a shared physical node (common ground-side return)
% that is metered by a Current Measurement block before reaching 'Out'.
% A powergui block (discrete, Ts = 50e-6 s) is included per CLAUDE.md.

modelName = 'emanuel_arc_subsystem';
subsysName = 'Emanuel_Arc_Fault';

scriptDir = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
modelsDir = fullfile(projectRoot, 'models');
if ~exist(modelsDir, 'dir')
    mkdir(modelsDir);
end
modelFile = fullfile(modelsDir, [modelName '.slx']);

%% Arc parameters (defaults; see CLAUDE.md Emanuel Arc Model Ranges)
% Vp: 500-8000 V | Vn: 1000-10000 V | Rp, Rn: 120-5000 Ohm
Vp_arc = 1500;  % Positive arc breakdown voltage (V)
Vn_arc = 2000;  % Negative arc breakdown voltage (V)
Rp_arc = 200;   % Positive-branch arcing/soil resistance (Ohm)
Rn_arc = 300;   % Negative-branch arcing/soil resistance (Ohm)

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
    error('build_emanuel_arc:LibraryNotFound', ...
        ['Specialized Power Systems library not found. ' ...
         'Verify Simscape Electrical is installed.']);
end

diodeBlk        = [libRoot '/Power Electronics/Diode'];
dcSrcBlk        = [libRoot '/Sources/DC Voltage Source'];
resistorBlk     = [libRoot '/Passives/Series RLC Branch'];
powerguiBlk     = [libRoot '/powergui'];
currentMeasBlk  = [libRoot '/Sensors and Measurements/Current Measurement'];
connPortBlk     = 'nesl_utility/Connection Port';
terminatorBlk   = 'simulink/Sinks/Terminator';

%% Start clean
if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
new_system(modelName);
open_system(modelName);

%% Bind arc parameters into the Model Workspace so the model resolves
%  Vp_arc/Vn_arc/Rp_arc/Rn_arc standalone, without depending on the base
%  MATLAB workspace being populated by this script at simulation time.
mdlWks = get_param(modelName, 'ModelWorkspace');
assignin(mdlWks, 'Vp_arc', Vp_arc);
assignin(mdlWks, 'Vn_arc', Vn_arc);
assignin(mdlWks, 'Rp_arc', Rp_arc);
assignin(mdlWks, 'Rn_arc', Rn_arc);

%% Build the reusable fault subsystem as an empty shell, then populate it
%  directly with explicit physical Connection Port blocks ('In'/'Out')
%  and the arc-branch circuitry, wiring everything by named port so the
%  interface is exactly two clean external terminals (no stray auto-ported
%  measurement signals left dangling).
subsysPath = [modelName '/' subsysName];
add_block('built-in/Subsystem', subsysPath, 'Position', [120 60 420 340]);

add_block(connPortBlk, [subsysPath '/In'], 'Position', [40 190 70 210]);
add_block(connPortBlk, [subsysPath '/Out'], 'Position', [460 190 490 210]);

% --- Branch P (positive half-cycle): In -[Anode]Diode_P[Cathode]- Vp -> Rp -> common node ---
% Snubbers are enabled on both diodes so the branch always has a
% finite-impedance path even when both diodes are simultaneously off
% (otherwise the arc branch floats when embedded in a larger network with
% the fault de-energized, producing a singular network admittance matrix).
% The snubber is purely resistive (Rs = 1 MOhm, Cs = inf). The earlier
% 500 Ohm + 250 nF RC snubber (~10.6 kOhm at 60 Hz) leaked ~0.6 A peak
% around the "off" diodes - verify_emanuel_arc.m showed 0.57 A flowing in a
% never-striking arc and a weak arc (Vp 2.5 kV, Rp 1 kOhm, 0.9 A ideal)
% buried in that leakage (corr 0.62). With 1 MOhm the leakage is < 10 mA.
add_block(diodeBlk, [subsysPath '/Diode_P'], 'Position', [140 100 180 130]);
set_param([subsysPath '/Diode_P'], 'Measurements', 'off', 'UseSnubber', '1', ...
    'Rs', '1e6', 'Cs', 'inf');

add_block(dcSrcBlk, [subsysPath '/Vp'], 'Position', [220 100 260 130]);
set_param([subsysPath '/Vp'], 'Amplitude', 'Vp_arc');

add_block(resistorBlk, [subsysPath '/Rp'], 'Position', [300 100 340 130]);
set_param([subsysPath '/Rp'], 'BranchType', 'R', 'Resistance', 'Rp_arc');

% --- Branch N (negative half-cycle): In -[Cathode]Diode_N[Anode]- Vn -> Rn -> common node
%     (antiparallel to Branch P: Diode_N's cathode faces 'In', so it
%     conducts on the opposite half-cycle) ---
add_block(diodeBlk, [subsysPath '/Diode_N'], 'Position', [140 280 180 310]);
set_param([subsysPath '/Diode_N'], 'Measurements', 'off', 'UseSnubber', '1', ...
    'Rs', '1e6', 'Cs', 'inf');

add_block(dcSrcBlk, [subsysPath '/Vn'], 'Position', [220 280 260 310]);
set_param([subsysPath '/Vn'], 'Amplitude', 'Vn_arc');

add_block(resistorBlk, [subsysPath '/Rn'], 'Position', [300 280 340 310]);
set_param([subsysPath '/Rn'], 'BranchType', 'R', 'Resistance', 'Rn_arc');

% --- Common node: Rp and Rn ground-side terminals join and are metered
%     by a Current Measurement block before reaching 'Out'. ---
add_block(currentMeasBlk, [subsysPath '/I_arc'], 'Position', [380 190 420 210]);

% The Current Measurement block's diagnostic signal output (port 1) is
% not part of the physical arc path; terminate it so it is not left
% unconnected.
add_block(terminatorBlk, [subsysPath '/Term_I_arc'], 'Position', [380 250 400 270]);

%% Wiring
% NOTE ON SOURCE POLARITY: for the SPS DC Voltage Source, LConn1 is the '-'
% terminal and RConn1 is the '+' terminal. Branch P must therefore present
% its '+' terminal to the diode cathode, so that the branch obeys
%     I = (V_fault - Vp_arc) / Rp_arc,  conducting only for V_fault > +Vp_arc.
% Wiring it the other way round (cathode -> LConn1) silently inverts the
% threshold to -Vp_arc, which makes the branch conduct on ~94% of the cycle
% and turns the "high impedance fault" into a near-continuous Rp_arc shunt.
add_line(subsysPath, 'In/RConn1', 'Diode_P/LConn1', 'autorouting', 'on');
add_line(subsysPath, 'Diode_P/RConn1', 'Vp/RConn1', 'autorouting', 'on');
add_line(subsysPath, 'Vp/LConn1', 'Rp/LConn1', 'autorouting', 'on');
add_line(subsysPath, 'Rp/RConn1', 'I_arc/LConn1', 'autorouting', 'on');

% Branch N is traversed in the opposite direction by its conduction current
% (ground -> Rn -> Vn -> Diode_N -> In), so the SAME relative source
% orientation that is wrong for branch P is correct here: it yields
%     I = -(Vn_arc + V_fault) / Rn_arc,  conducting only for V_fault < -Vn_arc.
add_line(subsysPath, 'In/RConn1', 'Diode_N/RConn1', 'autorouting', 'on');
add_line(subsysPath, 'Diode_N/LConn1', 'Vn/LConn1', 'autorouting', 'on');
add_line(subsysPath, 'Vn/RConn1', 'Rn/LConn1', 'autorouting', 'on');
add_line(subsysPath, 'Rn/RConn1', 'I_arc/LConn1', 'autorouting', 'on');

add_line(subsysPath, 'I_arc/RConn1', 'Out/RConn1', 'autorouting', 'on');
add_line(subsysPath, 'I_arc/1', 'Term_I_arc/1', 'autorouting', 'on');

add_block(powerguiBlk, [modelName '/powergui'], 'Position', [400 20 460 60]);
set_param([modelName '/powergui'], 'SimulationMode', 'Discrete', ...
    'SampleTime', '50e-6');

%% Save
save_system(modelName, modelFile);
close_system(modelName, 0);

fprintf('Emanuel Arc subsystem model saved to: %s\n', modelFile);
