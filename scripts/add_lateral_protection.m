%% add_lateral_protection.m
% Adds lateral-head protection and metering to BOTH ieee13_physical.slx and
% ieee13_digital_twin.slx (identically, so the twin keeps the physical
% feeder's exact topology):
%
%   Lateral 633 (Bus 632 -> Line_632_633 -> Bus 633 -> XFM_633_634 -> 634):
%       Bus 632 -> Brk_632_633 -> VI_633L -> Line_632_633
%   Lateral 675 (Bus 692 -> Line_692_675 -> Bus 675):
%       Bus 692 -> Brk_692_675 -> VI_675L -> Line_692_675
%
% Brk_* are Three-Phase Breakers, normally CLOSED and never switching
% (SwitchTimes '[1e6]'); build_twin_system.m turns their External control
% on and drives them from the in-model HIF relays. VI_* are Three-Phase V-I
% Measurement blocks (current only) whose outputs are logged as I_633L /
% I_675L - the lateral-head currents the digital-twin residual
% dI = I_physical - I_twin is formed from, so a HIF is both detected and
% LOCATED (633 vs 675) by which lateral's residual shows it. The substation
% current I_650 alone cannot distinguish the two laterals reliably.
%
% Each lateral line's own LConn connections are cut (only that line's
% branch of the bus node - every other block on Bus 632 / Bus 692 stays
% connected) and re-made through the breaker and meter. Idempotent: a model
% that already has Brk_632_633 is left untouched.
%
% Requires: Simulink, Simscape Electrical (Specialized Power Systems).

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
modelsDir   = fullfile(projectRoot, 'models');
addpath(scriptDir);   % HIFStreamDashboardBlock (dashboard tap inside ieee13_physical)

load_system('sps_lib');
brkBlk = 'sps_lib/Power Grid Elements/Three-Phase Breaker';
viBlk  = 'sps_lib/Sensors and Measurements/Three-Phase V-I Measurement';

% name, bus-side ports (feeding the lateral), lateral line, breaker, meter, logged signal
laterals = struct( ...
    'busPorts', {{'Line_650_632/RConn1', 'Line_650_632/RConn2', 'Line_650_632/RConn3'}, ...
                 {'Tie_671_692/RConn1', 'Tie_671_692/RConn2', 'Tie_671_692/RConn3'}}, ...
    'line',     {'Line_632_633', 'Line_692_675'}, ...
    'breaker',  {'Brk_632_633', 'Brk_692_675'}, ...
    'meter',    {'VI_633L', 'VI_675L'}, ...
    'signal',   {'I_633L', 'I_675L'});

for mdlName = ["ieee13_physical", "ieee13_digital_twin"]
    modelName = char(mdlName);
    modelFile = fullfile(modelsDir, [modelName '.slx']);
    if bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
    load_system(modelFile);
    fprintf('=== %s ===\n', modelName);

    changed = false;
    for k = 1:numel(laterals)
        lat = laterals(k);
        if getSimulinkBlockHandle([modelName '/' lat.breaker]) > 0
            fprintf('  %s already present - skipped\n', lat.breaker);
            continue;
        end
        insertLateralProtection(modelName, brkBlk, viBlk, lat);
        changed = true;
        fprintf('  Inserted %s + %s ahead of %s (logged as %s)\n', ...
            lat.breaker, lat.meter, lat.line, lat.signal);
    end

    if changed
        save_system(modelName, modelFile);
    end
    close_system(modelName, 0);
end

%% ======================================================================
function insertLateralProtection(modelName, brkBlk, viBlk, lat)
linePath = [modelName '/' lat.line];
lh = get_param(linePath, 'LineHandles');
for p = 1:3
    if lh.LConn(p) > 0 && ishandle(lh.LConn(p))
        delete_line(lh.LConn(p));
    end
end

pos = get_param(linePath, 'Position');
brkPath = [modelName '/' lat.breaker];
viPath  = [modelName '/' lat.meter];
add_block(brkBlk, brkPath, 'Position', pos + [-260 0 -260 0]);
% SwitchTimes must never be empty (mask-init error); '[1e6]' = never.
set_param(brkPath, 'InitialState', 'closed', 'External', 'off', 'SwitchTimes', '[1e6]');
add_block(viBlk, viPath, 'Position', pos + [-130 0 -130 0]);
set_param(viPath, 'VoltageMeasurement', 'no', 'CurrentMeasurement', 'yes');

for p = 1:3
    add_line(modelName, lat.busPorts{p}, sprintf('%s/LConn%d', lat.breaker, p), 'autorouting', 'on');
    add_line(modelName, sprintf('%s/RConn%d', lat.breaker, p), sprintf('%s/LConn%d', lat.meter, p), 'autorouting', 'on');
    add_line(modelName, sprintf('%s/RConn%d', lat.meter, p), sprintf('%s/LConn%d', lat.line, p), 'autorouting', 'on');
end

% Log the 3-phase lateral current; a Terminator keeps the output port used.
termPath = [viPath '_Term'];
add_block('simulink/Sinks/Terminator', termPath, 'Position', pos + [-130 70 -110 90]);
add_line(modelName, [lat.meter '/1'], [lat.meter '_Term/1'], 'autorouting', 'on');
ph = get_param(viPath, 'PortHandles');
set_param(ph.Outport(1), 'DataLogging', 'on', 'DataLoggingNameMode', 'Custom', ...
    'DataLoggingName', lat.signal);
end
