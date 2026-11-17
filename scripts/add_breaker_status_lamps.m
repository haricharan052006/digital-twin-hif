function add_breaker_status_lamps(sysName)
%ADD_BREAKER_STATUS_LAMPS  Live breaker-status lamps on the canvas of
% ieee13_hif_twin_system.slx (model must be loaded; the caller saves it).
%
% Adds Simulink Dashboard Lamp blocks bound to the breaker commands
% BrkCmd_633 / BrkCmd_675 (Auto/Manual selector output; falls back to the
% relay close commands CloseCmd_633 / CloseCmd_675 if the operator controls
% are absent) - 1 = breaker closed, 0 = tripped open:
%   - top level, beside the relays:            BrkLamp_633, BrkLamp_675
%   - next to Brk_632_633 / Brk_692_675 inside
%     Physical_Feeder AND Digital_Twin:        BrkLamp_633, BrkLamp_675
% GREEN = CLOSED, RED = TRIPPED / OPEN, grey before the run starts.
% Each lamp gets a canvas note explaining it.
%
% Non-invasive: Dashboard blocks have no ports - they read the bound
% signal while a Normal-mode simulation runs - so no line, port,
% connection, solver or configuration parameter is touched and the
% simulation results are unchanged. Idempotent: existing lamps and their
% notes (tag 'BrkLampNote') are replaced.

GREEN = [0.13 0.70 0.30];
RED   = [0.90 0.12 0.10];
LAMP  = 'simulink_hmi_blocks/Lamp';
load_system('simulink_hmi_blocks');

% {subsystem ('' = top level), lateral, anchor block, lamp offset from
% anchor's top-left corner, lamp size}
places = {
    '',                '633', 'CloseCmd_633', [200 -20], 50
    '',                '675', 'CloseCmd_675', [200 -20], 50
    'Physical_Feeder', '633', 'Brk_632_633',  [-5 80],   44
    'Physical_Feeder', '675', 'Brk_692_675',  [-5 80],   44
    'Digital_Twin',    '633', 'Brk_632_633',  [-5 80],   44
    'Digital_Twin',    '675', 'Brk_692_675',  [-5 80],   44};
names = containers.Map({'633', '675'}, {'Brk 632-633', 'Brk 692-675'});

for k = 1:size(places, 1)
    [sub, lat, anchor, offset, sz] = places{k, :};
    parent = sysName;
    if ~isempty(sub)
        parent = [sysName '/' sub];
    end
    lampPath = [parent '/BrkLamp_' lat];
    if getSimulinkBlockHandle(lampPath) > 0
        delete_block(lampPath);
    end
    old = find_system(parent, 'SearchDepth', 1, 'FindAll', 'on', 'Type', 'annotation', ...
        'Tag', ['BrkLampNote_' lat]);
    for a = old(:)'
        delete(get_param(a, 'Object'));
    end

    a = get_param([parent '/' anchor], 'Position');
    x = a(1) + offset(1);
    y = a(2) + offset(2);
    add_block(LAMP, lampPath, 'Position', [x, y, x + sz, y + sz]);

    % Bind to the command the breakers actually receive: BrkCmd_<lat>
    % (Auto/Manual selector, add_operator_controls.m) when present,
    % otherwise the relay's CloseCmd_<lat>.
    src = [sysName '/BrkCmd_' lat];
    if getSimulinkBlockHandle(src) <= 0
        src = [sysName '/CloseCmd_' lat];
    end
    sig = Simulink.HMI.SignalSpecification;
    sig.BlockPath = Simulink.BlockPath(src);
    sig.OutputPortIndex = 1;
    set_param(lampPath, 'Binding', sig, 'LabelPosition', 'Hide', ...
        'ColorDefault', [0.75 0.75 0.75], ...
        'StateColors', struct('Value', {1, 0}, 'Color', {GREEN, RED}));

    if isempty(sub)
        where = 'feeder + twin';
    elseif strcmp(sub, 'Physical_Feeder')
        where = 'feeder';
    else
        where = 'twin mirror';
    end
    note = Simulink.Annotation(parent, sprintf('%s (%s)\nGREEN = CLOSED\nRED = TRIPPED / OPEN', ...
        names(lat), where));
    note.Position = [x + sz + 8, y, x + sz + 150, y + sz];
    note.Tag = ['BrkLampNote_' lat];
    note.FontSize = 9;
end
end
