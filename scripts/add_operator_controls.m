function add_operator_controls(sysName)
%ADD_OPERATOR_CONTROLS  Auto/Manual operator control of the lateral
% breakers in ieee13_hif_twin_system.slx, with an independent manual trip
% command per lateral (model must be loaded; the caller saves it).
%
% Adds, on the top level:
%   Control_Mode         Constant, 1 = Auto (default) / 0 = Manual
%   Manual_Trip_633      Constant, 1 = Normal / Closed (default) / 0 = Isolate / Trip
%                        -> breaker 632-633 only
%   Manual_Trip_675      Constant, 1 = Normal / Closed (default) / 0 = Isolate / Trip
%                        -> breaker 692-675 only
%   Control_Mode_Switch, Manual_Trip_633_Switch, Manual_Trip_675_Switch
%                        Dashboard Toggle Switches bound to those Constant
%                        'Value' parameters (flip them during a run)
%   BrkCmd_633 / BrkCmd_675
%                        Switch blocks:  Control_Mode = 1 -> CloseCmd_<lat>
%                        (the ML relay's close command = 1 - trip);
%                        Control_Mode = 0 -> Manual_Trip_<lat>.
% Each BrkCmd output drives the lateral breaker in Physical_Feeder AND its
% mirror in Digital_Twin (the lines that came from CloseCmd_<lat>), so the
% twin keeps tracking the feeder's breaker state in both modes.
%
% With the defaults (Auto, Closed, Closed) every breaker command equals the
% CloseCmd signal sample-for-sample, so simulation results are unchanged.
% Electrical blocks, lines and solver settings are untouched.
%
% Re-running is safe: a model that already has Manual_Trip_633 is skipped.
% A model built with the earlier single shared Manual_Trip_Command is
% upgraded in place - that command, the toggles and the operator notes are
% replaced; the BrkCmd selectors, their breaker lines and Control_Mode stay.

if getSimulinkBlockHandle([sysName '/Manual_Trip_633']) > 0
    fprintf('add_operator_controls: per-lateral controls already installed in %s - skipped\n', sysName);
    return;
end
load_system('simulink_hmi_blocks');
Ts = '50e-6';
laterals = {'633', 1, [1030 228 1070 268], [1250 690 1310 720], [1345 660 1455 755], 'Brk 632-633'; ...
            '675', 2, [1030 448 1070 488], [1250 820 1310 850], [1345 790 1455 885], 'Brk 692-675'};

if getSimulinkBlockHandle([sysName '/BrkCmd_633']) > 0
    % Upgrade from the shared Manual_Trip_Command layout.
    removeBlock([sysName '/Manual_Trip_Command']);
    removeBlock([sysName '/Manual_Trip_Switch']);
    removeBlock([sysName '/Control_Mode_Switch']);
    notes = find_system(sysName, 'SearchDepth', 1, 'FindAll', 'on', 'Type', 'annotation', ...
        'Tag', 'OperatorControlNote');
    for a = notes(:)'
        delete(get_param(a, 'Object'));
    end
    fprintf('add_operator_controls: replaced the shared Manual_Trip_Command in %s\n', sysName);
else
    % Operator mode (sampled at Ts so a change during the run takes effect
    % at the next step).
    add_block('simulink/Sources/Constant', [sysName '/Control_Mode'], 'Value', '1', ...
        'SampleTime', Ts, 'Position', [1250 560 1310 590]);
    % Auto/Manual selection per lateral, between CloseCmd and the breakers.
    for k = 1:size(laterals, 1)
        [lat, port, pos] = laterals{k, 1:3};
        sel = ['BrkCmd_' lat];
        add_block('simulink/Signal Routing/Switch', [sysName '/' sel], 'Criteria', 'u2 > Threshold', ...
            'Threshold', '0.5', 'Position', pos);
        delete_line(sysName, ['CloseCmd_' lat '/1'], sprintf('Physical_Feeder/%d', port));
        delete_line(sysName, ['CloseCmd_' lat '/1'], sprintf('Digital_Twin/%d', port));
        add_line(sysName, ['CloseCmd_' lat '/1'], [sel '/1'], 'autorouting', 'smart');
        add_line(sysName, 'Control_Mode/1', [sel '/2'], 'autorouting', 'smart');
        add_line(sysName, [sel '/1'], sprintf('Physical_Feeder/%d', port), 'autorouting', 'smart');
        add_line(sysName, [sel '/1'], sprintf('Digital_Twin/%d', port), 'autorouting', 'smart');
    end
end

% One manual trip command per lateral, into that lateral's selector only.
for k = 1:size(laterals, 1)
    [lat, ~, ~, pos] = laterals{k, 1:4};
    add_block('simulink/Sources/Constant', [sysName '/Manual_Trip_' lat], 'Value', '1', ...
        'SampleTime', Ts, 'Position', pos);
    add_line(sysName, ['Manual_Trip_' lat '/1'], ['BrkCmd_' lat '/3'], 'autorouting', 'smart');
end

% Dashboard toggles bound to the Constant values, each with a caption.
tripStates = struct('Value', {0, 1}, 'Label', {'Isolate / Trip', 'Normal / Closed'});
toggles = {'Control_Mode_Switch', 'Control_Mode', [1345 530 1455 625], ...
              struct('Value', {0, 1}, 'Label', {'Manual', 'Auto'}), 'Control_Mode'};
for k = 1:size(laterals, 1)
    [lat, ~, ~, ~, tpos, brk] = laterals{k, :};
    toggles(end + 1, :) = {['Manual_Trip_' lat '_Switch'], ['Manual_Trip_' lat], tpos, tripStates, ...
        sprintf('Manual_Trip_%s (%s)', lat, brk)}; %#ok<AGROW>
end
for k = 1:size(toggles, 1)
    [name, target, pos, states, label] = toggles{k, :};
    blk = [sysName '/' name];
    add_block('simulink_hmi_blocks/Toggle Switch', blk, 'Position', pos);
    bind = Simulink.HMI.ParamSourceInfo;
    bind.BlockPath = Simulink.BlockPath([sysName '/' target]);
    bind.ParamName = 'Value';
    bind.Label = target;
    set_param(blk, 'Binding', bind, 'States', states, 'LabelPosition', 'Hide');
    % Caption starts over the toggle, clear of the wires that run up
    % between the Constant blocks and the toggles (x ~ 1315-1335).
    caption = Simulink.Annotation(sysName, label);
    caption.Position = [pos(1) + 5, pos(2) - 22, pos(1) + 175, pos(2) - 4];
    caption.Tag = 'OperatorControlNote';
    caption.FontSize = 11;
    caption.FontWeight = 'bold';
end

note = Simulink.Annotation(sysName, sprintf(['OPERATOR CONTROL\n' ...
    'Control_Mode: Auto = breakers follow the ML relays\n' ...
    '              Manual = each breaker follows its own manual toggle\n' ...
    'Manual_Trip_633 -> Brk 632-633    Manual_Trip_675 -> Brk 692-675\n' ...
    'Normal / Closed or Isolate / Trip\n' ...
    '(each acts on its feeder breaker and twin mirror together)']));
note.Position = [1475 560 1795 720];
note.Tag = 'OperatorControlNote';
note.FontSize = 9;
end

%% ======================================================================
function removeBlock(blk)
% Delete a block and every line attached to it (no-op if absent).
if getSimulinkBlockHandle(blk) <= 0
    return;
end
lh = get_param(blk, 'LineHandles');
for f = fieldnames(lh)'
    h = lh.(f{1});
    for j = 1:numel(h)
        if h(j) > 0 && ishandle(h(j))
            delete_line(h(j));
        end
    end
end
delete_block(blk);
end
