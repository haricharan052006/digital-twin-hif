function add_isolation_scope(sysName)
%ADD_ISOLATION_SCOPE  Top-level Scope_Isolated_Current for
% ieee13_hif_twin_system.slx (model must be loaded; the caller saves it).
%
% Displays the PHYSICAL feeder's lateral-head 3-phase currents, measured
% just downstream of the protective breakers (Physical_Feeder outputs
% I_633L = port 2 and I_675L = port 3):
%   display 1  lateral 632-633 (Brk_632_633 -> VI_633L)
%   display 2  lateral 692-675 (Brk_692_675 -> VI_675L)
% over the full 0.30 s run, so the panel sees nominal load current, the
% fault, and the clean flatline to 0 A once the relay trips the breaker.
%
% Display-only: two new sink branches from existing outputs; no existing
% line, port, connection, solver or configuration parameter is touched.
% The scope does not log data (logsout is unchanged) and does not open
% automatically during simulation (batch runs are unaffected) - open it
% with open_system('<model>/Scope_Isolated_Current'). Idempotent.

scopeName = 'Scope_Isolated_Current';
scope = [sysName '/' scopeName];
if getSimulinkBlockHandle(scope) > 0
    lh = get_param(scope, 'LineHandles');
    for h = lh.Inport(lh.Inport > 0)
        delete_line(h);
    end
    delete_block(scope);
end
old = find_system(sysName, 'SearchDepth', 1, 'FindAll', 'on', 'Type', 'annotation', ...
    'Tag', 'IsolationScopeNote');
for a = old(:)'
    delete(get_param(a, 'Object'));
end

% Free strip between Physical_Feeder and Digital_Twin, beside the outputs.
add_block('simulink/Sinks/Scope', scope, 'NumInputPorts', '2', ...
    'Position', [452 322 504 372]);
add_line(sysName, 'Physical_Feeder/2', [scopeName '/1'], 'autorouting', 'smart');
add_line(sysName, 'Physical_Feeder/3', [scopeName '/2'], 'autorouting', 'smart');

stopTime = str2double(get_param(sysName, 'StopTime'));
cfg = get_param(scope, 'ScopeConfiguration');
cfg.LayoutDimensions = [2 1];
cfg.TimeSpan = num2str(stopTime);
cfg.TimeSpanOverrunAction = 'Wrap';
cfg.AxesScaling = 'Manual';
cfg.ShowGrid = true;
cfg.ShowLegend = false;
cfg.DataLogging = false;
cfg.OpenAtSimulationStart = false;
cfg.Position = [100 100 1000 650];   % (cfg.Name would rename the block)
displays = {
    'Lateral 632-633 head current I_{633L}, phases A/B/C  (Brk 632-633 trips -> 0 A)', [-120 120]
    'Lateral 692-675 head current I_{675L}, phases A/B/C  (Brk 692-675 trips -> 0 A)', [-300 300]};
for d = 1:2
    cfg.ActiveDisplay = d;
    cfg.Title = displays{d, 1};
    cfg.YLabel = 'Current (A)';
    cfg.YLimits = displays{d, 2};
end
cfg.ActiveDisplay = 1;

note = Simulink.Annotation(sysName, sprintf(['Scope_Isolated_Current: physical lateral\n' ...
    'currents after the breakers - flatline to 0 A\nwhen the relay trips (double-click to open)']));
note.Position = [215 352 442 402];
note.Tag = 'IsolationScopeNote';
note.FontSize = 9;
end
