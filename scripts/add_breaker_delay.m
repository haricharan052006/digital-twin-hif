function add_breaker_delay(sysName)
%ADD_BREAKER_DELAY  Mechanical breaker operating time in the relay trip path
% of ieee13_hif_twin_system.slx (model must be loaded; the caller saves it).
%
% Inserts, for each lateral, a Delay block BrkOpDelay_<lat> between the
% relay's close command CloseCmd_<lat> (= 1 - trip) and the Auto/Manual
% selector BrkCmd_<lat>, so the trip reaches the feeder breaker AND its twin
% mirror BrkOpDelaySteps samples (of Ts = 50 us) after the relay asserts it:
% contacts part at t_trip + BrkOpDelaySteps * Ts, and the Simscape breaker
% then interrupts at the next current zero. The manual operator path is not
% delayed.
%
%   BrkOpDelaySteps   model-workspace variable, default 0 (no delay - the
%                     model then behaves sample for sample as before);
%                     run_twin_isolation_case(..., 'BreakerDelayCycles', c)
%                     sets it per run: 3 cycles = 1000, 5 cycles = 1667 samples
% Delay initial condition 1 = breaker closed. The delayed command is logged as
% CloseCmdDelayed_<lat>.
%
% Re-running is safe: a model that already has BrkOpDelay_633 is skipped.

if getSimulinkBlockHandle([sysName '/BrkOpDelay_633']) > 0
    fprintf('add_breaker_delay: already installed in %s - skipped\n', sysName);
    return;
end
wks = get_param(sysName, 'ModelWorkspace');
assignin(wks, 'BrkOpDelaySteps', 0);

for lat = {'633', '675'}
    cmd = ['CloseCmd_' lat{1}];
    sel = ['BrkCmd_' lat{1}];
    dly = ['BrkOpDelay_' lat{1}];
    pc = get_param([sysName '/' cmd], 'Position');
    ps = get_param([sysName '/' sel], 'Position');
    x = round((pc(3) + ps(1)) / 2) - 20;
    y = round((pc(2) + pc(4)) / 2);
    delete_line(sysName, [cmd '/1'], [sel '/1']);
    add_block('simulink/Discrete/Delay', [sysName '/' dly], 'DelayLengthSource', 'Dialog', ...
        'DelayLength', 'BrkOpDelaySteps', 'InitialCondition', '1', 'SampleTime', '-1', ...
        'Position', [x, y - 15, x + 40, y + 15], 'NameLocation', 'top');
    add_line(sysName, [cmd '/1'], [dly '/1'], 'autorouting', 'smart');
    add_line(sysName, [dly '/1'], [sel '/1'], 'autorouting', 'smart');
    ph = get_param([sysName '/' dly], 'PortHandles');
    set_param(ph.Outport(1), 'DataLogging', 'on', 'DataLoggingNameMode', 'Custom', ...
        'DataLoggingName', ['CloseCmdDelayed_' lat{1}]);
end
note = Simulink.Annotation(sysName, sprintf(['BREAKER OPERATING TIME\n' ...
    'BrkOpDelay_633 / _675 delay the relay trip by BrkOpDelaySteps x 50 us\n' ...
    '(model workspace, default 0; 3 cycles = 1000, 5 cycles = 1667)']));
pc = get_param([sysName '/CloseCmd_633'], 'Position');
note.Position = [pc(1) - 20, pc(2) - 110, pc(1) + 330, pc(2) - 60];
note.FontSize = 9;
fprintf('add_breaker_delay: installed BrkOpDelay_633 / _675 in %s\n', sysName);
end
