function add_relay_interlock(sysName)
%ADD_RELAY_INTERLOCK  Inter-relay blocking interlock (RelayInterlockBlock.m)
% between the two lateral HIF relays of ieee13_hif_twin_system.slx (model
% must be loaded; the caller saves it).
%
% Inserts Relay_Interlock between each relay's trip output and its
% CloseCmd_<lat> (1 - trip), feeds it both lateral residuals, and returns a
% block signal to each relay (HIF_Relay_<lat> UseBlockInput = true). The
% raw relay trips stay logged as Trip_<lat>; the trips that reach the
% breakers are logged as TripOut_<lat>.
%
% Model-workspace variables:
%   InterlockEnable       0 (default) = pass-through, the model behaves sample
%                         for sample as before; 1 = interlock on
%                         (run_twin_isolation_case(..., 'Interlock', true))
%   InterlockMarginSteps  1200 samples (60 ms) added to BrkOpDelaySteps for the
%                         block length: the blocked relay's two-cycle window
%                         (667) + the slowest arc extinction seen (~218) + one
%                         decision period (167), rounded up
%
% Re-running is safe: a model that already has Relay_Interlock is skipped.

blk = [sysName '/Relay_Interlock'];
if getSimulinkBlockHandle(blk) > 0
    fprintf('add_relay_interlock: already installed in %s - skipped\n', sysName);
    return;
end
wks = get_param(sysName, 'ModelWorkspace');
assignin(wks, 'InterlockEnable', 0);
assignin(wks, 'InterlockMarginSteps', 1200);

p633 = get_param([sysName '/HIF_Relay_633'], 'Position');
p675 = get_param([sysName '/HIF_Relay_675'], 'Position');
x = p633(3) + 30;
y = round((p633(2) + p675(4)) / 2) - 10;
add_block('simulink/User-Defined Functions/MATLAB System', blk, 'System', 'RelayInterlockBlock', ...
    'Position', [x, y - 40, x + 140, y + 40], 'ShowName', 'off');
set_param(blk, 'SimulateUsing', 'Interpreted execution', 'Enable', 'InterlockEnable', ...
    'BlockSteps', 'BrkOpDelaySteps + InterlockMarginSteps', 'EnergyWindow', '667');

lats = {'633', '675'};
for k = 1:2
    relay = ['HIF_Relay_' lats{k}];
    set_param([sysName '/' relay], 'UseBlockInput', 'on');
    delete_line(sysName, [relay '/1'], ['CloseCmd_' lats{k} '/2']);
    add_line(sysName, [relay '/1'], sprintf('Relay_Interlock/%d', k), 'autorouting', 'smart');
    add_line(sysName, ['dI_' lats{k} 'L/1'], sprintf('Relay_Interlock/%d', k + 2), 'autorouting', 'smart');
    add_line(sysName, sprintf('Relay_Interlock/%d', k), ['CloseCmd_' lats{k} '/2'], 'autorouting', 'smart');
    add_line(sysName, sprintf('Relay_Interlock/%d', k + 2), [relay '/2'], 'autorouting', 'smart');
    ph = get_param(blk, 'PortHandles');
    set_param(ph.Outport(k), 'DataLogging', 'on', 'DataLoggingNameMode', 'Custom', ...
        'DataLoggingName', ['TripOut_' lats{k}]);
end
note = Simulink.Annotation(sysName, sprintf(['RELAY INTERLOCK (InterlockEnable, default 0 = pass-through)\n' ...
    'First relay to trip is granted; the neighbour is blocked for\n' ...
    'BrkOpDelaySteps + InterlockMarginSteps samples. Same-step tie ->\n' ...
    'larger 2-cycle residual energy wins.']));
note.Position = [p675(1), p675(4) + 50, p675(1) + 375, p675(4) + 96];   % free canvas below the relays
note.FontSize = 9;
fprintf('add_relay_interlock: installed Relay_Interlock in %s\n', sysName);
end
