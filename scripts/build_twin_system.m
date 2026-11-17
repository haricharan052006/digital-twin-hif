%% build_twin_system.m
% Builds models/ieee13_hif_twin_system.slx - the closed-loop digital-twin
% HIF protection system:
%
%   Physical_Feeder  (copy of ieee13_physical.slx: feeder + Emanuel-arc HIF
%                     branches at Buses 633/675 + switching decoys)
%   Digital_Twin     (copy of ieee13_digital_twin.slx: the same feeder,
%                     healthy, nominal loads)
%     Both electrical networks run in the SAME simulation under one
%     powergui (Discrete, Ts = 50e-6 s) - the twin runs in parallel with the
%     feeder rather than from a cached baseline.
%
%   Residuals        dI = I_physical - I_twin at the substation (I_650) and
%                    at each lateral head (I_633L, I_675L).
%   HIF_Relay_633 /  HIFRelayBlock (db4 5-level DWT features + Random
%   HIF_Relay_675    Forest, trained by train_classifiers.m) on each lateral
%                    residual; latched trip once ConfirmCount of the last
%                    ConfirmWindow decisions are HIF (default 2 of 3).
%   Trip -> breaker  close command = 1 - trip drives the lateral breaker
%                    (Brk_632_633 / Brk_692_675, External control) in the
%                    physical feeder AND the same breaker in the twin, so
%                    the twin mirrors the feeder's breaker status (as a real
%                    twin does from SCADA) and the post-trip residual
%                    returns to ~0.
%
% The fault scenario is set on the Physical_Feeder fault breakers /
% arc subsystems (default: FaultBreaker_675A closes at 0.05 s, as saved in
% ieee13_physical.slx); run_twin_isolation_case.m drives any scenario via
% Simulink.SimulationInput.
%
% Prerequisites: extend_fault_injection.m, add_lateral_protection.m (both
% feeder models), train_classifiers.m (models/hif_relay_model.mat - needed
% at simulation time, not to build).
%
% Requires: Simulink, Simscape Electrical (Specialized Power Systems).

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
modelsDir   = fullfile(projectRoot, 'models');
addpath(scriptDir);

sysName  = 'ieee13_hif_twin_system';
sysFile  = fullfile(modelsDir, [sysName '.slx']);
physName = 'ieee13_physical';
twinName = 'ieee13_digital_twin';
T_STOP   = 0.30;
SIGNALS  = {'I_650', 'I_633L', 'I_675L'};          % subsystem outports
METERS   = {'VI_650', 'VI_633L', 'VI_675L'};
LATERALS = struct('tag', {'633', '675'}, 'breaker', {'Brk_632_633', 'Brk_692_675'});

for m = {sysName, physName, twinName}
    if bdIsLoaded(m{1})
        close_system(m{1}, 0);
    end
end
load_system('sps_lib');
load_system(fullfile(modelsDir, [physName '.slx']));
load_system(fullfile(modelsDir, [twinName '.slx']));

new_system(sysName);
set_param(sysName, 'Solver', 'FixedStepDiscrete', 'FixedStep', '50e-6', ...
    'StopTime', num2str(T_STOP), 'SignalLogging', 'on', 'SignalLoggingName', 'logsout', ...
    'ReturnWorkspaceOutputs', 'on');

add_block('sps_lib/powergui', [sysName '/powergui'], 'Position', [30 20 100 60]);
set_param([sysName '/powergui'], 'SimulationMode', 'Discrete', 'SampleTime', '50e-6');

% Arc parameters referenced by the copied Emanuel_Arc_Fault_* subsystems.
physWks = get_param(physName, 'ModelWorkspace');
sysWks  = get_param(sysName, 'ModelWorkspace');
for v = {'Vp_arc', 'Vn_arc', 'Rp_arc', 'Rn_arc'}
    assignin(sysWks, v{1}, evalin(physWks, v{1}));
end

%% ---------------------------------------------- two networks, one model
% The twin's logged signals / To Workspace variables get a 'twin_' prefix
% so they do not collide with the feeder's identically named ones.
plant = {'Physical_Feeder', physName, [200 100 420 320], ''; ...
         'Digital_Twin',    twinName, [200 420 420 640], 'twin_'};
for i = 1:size(plant, 1)
    sub = [sysName '/' plant{i, 1}];
    add_block('built-in/Subsystem', sub, 'Position', plant{i, 3});
    Simulink.BlockDiagram.copyContentsToSubsystem(plant{i, 2}, sub);
    prepareNetwork(sub, METERS, SIGNALS, LATERALS, plant{i, 4});
    fprintf('  %s: copied from %s.slx\n', plant{i, 1}, plant{i, 2});
end
close_system(physName, 0);
close_system(twinName, 0);

%% ---------------------------------------------- residuals dI = I_phys - I_twin
for s = 1:numel(SIGNALS)
    sumName = ['dI_' SIGNALS{s}(3:end)];             % dI_650, dI_633L, dI_675L
    y = 120 + 110 * (s - 1);
    add_block('simulink/Math Operations/Sum', [sysName '/' sumName], ...
        'Inputs', '+-', 'Position', [560 y 590 y + 30]);
    add_line(sysName, sprintf('Physical_Feeder/%d', s), [sumName '/1'], 'autorouting', 'on');
    add_line(sysName, sprintf('Digital_Twin/%d', s), [sumName '/2'], 'autorouting', 'on');
    logPort([sysName '/' sumName], 1, sumName);
end

%% ---------------------------------------------- relays + closed-loop trip
for k = 1:numel(LATERALS)
    tag = LATERALS(k).tag;
    y = 230 + 220 * (k - 1);
    relay = ['HIF_Relay_' tag];
    add_block('simulink/User-Defined Functions/MATLAB System', [sysName '/' relay], ...
        'System', 'HIFRelayBlock', 'Position', [700 y 820 y + 60]);
    % Relay settings are set explicitly: a MATLAB System block stores its
    % property values in the model, so later changes to the class defaults
    % never reach an already-built block.
    set_param([sysName '/' relay], 'SimulateUsing', 'Interpreted execution', ...
        'EvalSteps', '167', 'ConfirmCount', '2', 'ConfirmWindow', '3');
    add_line(sysName, ['dI_' tag 'L/1'], [relay '/1'], 'autorouting', 'on');
    logPort([sysName '/' relay], 1, ['Trip_' tag]);
    logPort([sysName '/' relay], 2, ['Class_' tag]);

    % close command = 1 - trip, to the feeder breaker AND its twin mirror
    one = ['One_' tag];
    cmd = ['CloseCmd_' tag];
    add_block('simulink/Sources/Constant', [sysName '/' one], 'Value', '1', ...
        'Position', [880 y - 40 910 y - 20]);
    add_block('simulink/Math Operations/Sum', [sysName '/' cmd], 'Inputs', '+-', ...
        'Position', [950 y 980 y + 30]);
    add_line(sysName, [one '/1'], [cmd '/1'], 'autorouting', 'on');
    add_line(sysName, [relay '/1'], [cmd '/2'], 'autorouting', 'on');
    add_line(sysName, [cmd '/1'], sprintf('Physical_Feeder/%d', k), 'autorouting', 'on');
    add_line(sysName, [cmd '/1'], sprintf('Digital_Twin/%d', k), 'autorouting', 'on');

    term = ['ClassTerm_' tag];
    add_block('simulink/Sinks/Terminator', [sysName '/' term], 'Position', [880 y + 40 900 y + 60]);
    add_line(sysName, [relay '/2'], [term '/1'], 'autorouting', 'on');
end

%% ---------------------------------------------- scopes
add_block('simulink/Sinks/Scope', [sysName '/Scope_Residuals'], 'NumInputPorts', '3', ...
    'Position', [700 40 740 120]);
for s = 1:numel(SIGNALS)
    add_line(sysName, ['dI_' SIGNALS{s}(3:end) '/1'], sprintf('Scope_Residuals/%d', s), 'autorouting', 'on');
end
add_block('simulink/Sinks/Scope', [sysName '/Scope_Relays'], 'NumInputPorts', '2', ...
    'Position', [1060 300 1100 360]);
add_line(sysName, 'HIF_Relay_633/1', 'Scope_Relays/1', 'autorouting', 'on');
add_line(sysName, 'HIF_Relay_675/1', 'Scope_Relays/2', 'autorouting', 'on');

% Visual-only canvas layout of both feeder subsystems (block positions and
% line geometry; no connection changes).
layout_twin_system(sysName);
% Auto/Manual operator control between the relays and the breakers.
add_operator_controls(sysName);
% Dashboard lamps showing the breaker state live (no ports / connections).
add_breaker_status_lamps(sysName);
% Display-only scope of the physical lateral currents after the breakers.
add_isolation_scope(sysName);

save_system(sysName, sysFile);
close_system(sysName, 0);
fprintf('Saved %s\n', sysFile);

%% ======================================================================
function prepareNetwork(sub, meters, signals, laterals, prefix)
% Strip what a nested copy must not carry (its own powergui, the
% standalone dashboard tap), prefix its logging / To Workspace names,
% expose the three current meters as outports and put the lateral
% breakers under external (relay) control.
pg = find_system(sub, 'SearchDepth', 1, 'MaskType', 'PSB option menu block');
cellfun(@(b) delete_block(b), pg);

if ~isempty(prefix)
    tows = find_system(sub, 'LookUnderMasks', 'all', 'BlockType', 'ToWorkspace');
    for i = 1:numel(tows)
        set_param(tows{i}, 'VariableName', [prefix get_param(tows{i}, 'VariableName')]);
    end
    logged = find_system(sub, 'FindAll', 'on', 'LookUnderMasks', 'all', ...
        'Type', 'port', 'DataLogging', 'on');
    for i = 1:numel(logged)
        set_param(logged(i), 'DataLoggingNameMode', 'Custom', ...
            'DataLoggingName', [prefix get_param(logged(i), 'DataLoggingName')]);
    end
end

taps = find_system(sub, 'SearchDepth', 1, 'BlockType', 'MATLABSystem');
for i = 1:numel(taps)
    pc = get_param(taps{i}, 'PortConnectivity');
    srcs = [pc.SrcBlock];
    deleteBlockLines(taps{i});
    delete_block(taps{i});
    for s = srcs(srcs > 0)
        if strcmp(get_param(s, 'BlockType'), 'Clock')
            deleteBlockLines(getfullname(s));
            delete_block(s);
        end
    end
end

for s = 1:numel(meters)
    op = [sub '/' signals{s}];
    pos = get_param([sub '/' meters{s}], 'Position');
    add_block('simulink/Sinks/Out1', op, 'Port', num2str(s), ...
        'Position', [pos(3) + 60, pos(2), pos(3) + 90, pos(2) + 14]);
    add_line(sub, [meters{s} '/1'], [signals{s} '/1'], 'autorouting', 'on');
end

for k = 1:numel(laterals)
    brk = [sub '/' laterals(k).breaker];
    set_param(brk, 'External', 'on');
    ip = [sub '/Close_' laterals(k).tag];
    pos = get_param(brk, 'Position');
    add_block('simulink/Sources/In1', ip, 'Port', num2str(k), ...
        'Position', [pos(1) - 80, pos(2) - 40, pos(1) - 50, pos(2) - 26]);
    add_line(sub, ['Close_' laterals(k).tag '/1'], [laterals(k).breaker '/1'], 'autorouting', 'on');
end
end

%% ======================================================================
function deleteBlockLines(blk)
lh = get_param(blk, 'LineHandles');
for f = fieldnames(lh)'
    h = lh.(f{1});
    for j = 1:numel(h)
        if h(j) > 0 && ishandle(h(j))
            delete_line(h(j));
        end
    end
end
end

%% ======================================================================
function logPort(blk, portIdx, name)
ph = get_param(blk, 'PortHandles');
set_param(ph.Outport(portIdx), 'DataLogging', 'on', 'DataLoggingNameMode', 'Custom', ...
    'DataLoggingName', name);
end
