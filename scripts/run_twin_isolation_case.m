function r = run_twin_isolation_case(scenario, varargin)
%RUN_TWIN_ISOLATION_CASE  Runs one scenario on ieee13_hif_twin_system.slx
% (feeder + parallel digital twin + in-model HIF relays + closed-loop
% lateral trip) and reports what the protection did.
%
%   r = run_twin_isolation_case('hif', 'Bus', '675', 'Phase', 'A')
%   r = run_twin_isolation_case('hif', 'Bus', '633', 'Phase', 'C', ...
%           'Vp', 2400, 'Vn', 2500, 'Rp', 2000, 'Rn', 2000, 'TEvent', 0.1)
%   r = run_twin_isolation_case('none')          % healthy feeder
%   r = run_twin_isolation_case('cap675')        % 675 capacitor bank opens
%   r = run_twin_isolation_case('cap611')        % 611 phase-C capacitor opens
%   r = run_twin_isolation_case('loadstep')      % 671 step-load bank closes
%
% Name-value options: Bus ('633'|'675'), Phase ('A'|'B'|'C'), Vp, Vn, Rp,
% Rn (arc parameters, default 1500 V / 2000 V / 200 Ohm / 300 Ohm),
% TEvent (fault inception / switching time, default 0.10 s), StopTime
% (default 0.30 s), ModelFile (relay bundle override, default
% models/hif_relay_model.mat - e.g. models/hif_relay_lgbm.mat or
% models/hif_relay_cnn_wide.mat), BreakerDelayCycles (mechanical breaker
% operating time in 60 Hz cycles, default 0; sets BrkOpDelaySteps of
% add_breaker_delay.m to round(cycles / 60 / 50e-6) samples).
%
% r fields: scenario, bus, phase, tEvent, tripTime633 / tripTime675 (NaN =
% no trip), tripped ('633' | '675' | '633+675' | 'none'),
% classes633 / classes675 (relay classes seen), and lateral current /
% residual RMS before the event and over the last two cycles.
%
% Raw waveforms on one common time base, for direct plotting:
%   r.time                                [N x 1] s
%   r.I_650_physical, r.I_650_twin        [N x 3] substation current (A)
%   r.I_633_physical, r.I_633_twin        [N x 3] lateral-633 head current (A)
%   r.I_675_physical, r.I_675_twin        [N x 3] lateral-675 head current (A)
%   r.dI_650, r.dI_633, r.dI_675          [N x 3] residual I_physical - I_twin (A)
%   r.trip_633, r.trip_675                [N x 1] relay trip (0/1)
%   r.class_633, r.class_675              [N x 1] relay class (0 Normal, 1 Switching,
%                                                 2/3/4 HIF phase A/B/C)
%   r.I_arc                               [N x 1] faulted arc current (A), HIF only
%   r.closeCmd_633, r.closeCmd_675        [N x 1] relay close command after the
%                                                 breaker operating delay (1 closed, 0 open)
%   r.tripOut_633, r.tripOut_675          [N x 1] trip that reached the breaker command
%                                                 (after Relay_Interlock; r.trip_* are the
%                                                 raw relay latches)
% r.breakerDelayCycles / r.breakerDelaySteps / r.interlock record the settings.
% Option Interlock (default false) switches Relay_Interlock on
% (add_relay_interlock.m); tripTime* and tripped follow the trips that
% reached the breakers.
% e.g.  plot(r.time, r.dI_633)

p = inputParser;
p.addParameter('Bus', '675');
p.addParameter('Phase', 'A');
p.addParameter('Vp', 1500);
p.addParameter('Vn', 2000);
p.addParameter('Rp', 200);
p.addParameter('Rn', 300);
p.addParameter('TEvent', 0.10);
p.addParameter('StopTime', 0.30);
p.addParameter('ModelFile', '');
p.addParameter('BreakerDelayCycles', 0);
p.addParameter('Interlock', false);
p.parse(varargin{:});
o = p.Results;
bus = char(string(o.Bus));
phase = upper(char(o.Phase));

projectRoot = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(projectRoot, 'scripts'));
sysName = 'ieee13_hif_twin_system';
if ~bdIsLoaded(sysName)
    load_system(fullfile(projectRoot, 'models', [sysName '.slx']));
end
feeder = [sysName '/Physical_Feeder'];

in = Simulink.SimulationInput(sysName);
in = in.setModelParameter('StopTime', num2str(o.StopTime));
delaySteps = round(o.BreakerDelayCycles / 60 / 50e-6);
if delaySteps > 0
    in = in.setVariable('BrkOpDelaySteps', delaySteps, 'Workspace', sysName);
end
if o.Interlock
    in = in.setVariable('InterlockEnable', 1, 'Workspace', sysName);
end
if ~isempty(o.ModelFile)
    for relay = {'HIF_Relay_633', 'HIF_Relay_675'}
        in = in.setBlockParameter([sysName '/' relay{1}], 'ModelFile', o.ModelFile);
    end
end

% Every fault branch dead ('[1e6]', never '[]' - see verify_emanuel_arc.m),
% every decoy breaker in its no-event state.
for b = {'633', '675'}
    for ph = 'ABC'
        in = setParams(in, sprintf('%s/FaultBreaker_%s%s', feeder, b{1}, ph), ...
            'InitialState', '0', 'SwitchingTimes', '[1e6]');
    end
end
in = setParams(in, [feeder '/CapBrk_675'], 'InitialState', 'closed', 'SwitchTimes', '[1e6]');
in = setParams(in, [feeder '/LoadStepBrk_671'], 'InitialState', 'open', 'SwitchTimes', '[1e6]');
in = setParams(in, [feeder '/CapBrk_611C'], 'InitialState', '1', 'SwitchingTimes', '[1e6]');

tStr = sprintf('[%.6f]', o.TEvent);
switch lower(scenario)
    case 'hif'
        tag = [bus phase];
        in = in.setBlockParameter([feeder '/FaultBreaker_' tag], 'SwitchingTimes', tStr);
        arc = [feeder '/Emanuel_Arc_Fault_' tag];
        in = in.setBlockParameter([arc '/Vp'], 'Amplitude', num2str(o.Vp));
        in = in.setBlockParameter([arc '/Vn'], 'Amplitude', num2str(o.Vn));
        in = in.setBlockParameter([arc '/Rp'], 'Resistance', num2str(o.Rp));
        in = in.setBlockParameter([arc '/Rn'], 'Resistance', num2str(o.Rn));
    case 'cap675'
        in = in.setBlockParameter([feeder '/CapBrk_675'], 'SwitchTimes', tStr);
    case 'cap611'
        in = in.setBlockParameter([feeder '/CapBrk_611C'], 'SwitchingTimes', tStr);
    case 'loadstep'
        in = in.setBlockParameter([feeder '/LoadStepBrk_671'], 'SwitchTimes', tStr);
    case 'none'
    otherwise
        error('run_twin_isolation_case:BadScenario', 'Unknown scenario "%s".', scenario);
end

out = sim(in);
if ~isempty(out.ErrorMessage)
    error('run_twin_isolation_case:SimFailed', '%s', out.ErrorMessage);
end

r.scenario = lower(scenario);
r.bus = '';
r.phase = '';
if strcmp(r.scenario, 'hif')
    r.bus = bus;
    r.phase = phase;
end
r.tEvent = o.TEvent;
if strcmp(r.scenario, 'none')
    r.tEvent = NaN;
end
tripped = strings(0);
hasInterlock = ~isempty(out.logsout.find('Name', 'TripOut_633'));
for lat = {'633', '675'}
    % trip that reached the breaker (after the interlock, when the model has one)
    if hasInterlock
        trip = out.logsout.get(['TripOut_' lat{1}]).Values;
    else
        trip = out.logsout.get(['Trip_' lat{1}]).Values;
    end
    cls = out.logsout.get(['Class_' lat{1}]).Values;
    k = find(squeeze(trip.Data) > 0.5, 1);
    if isempty(k)
        r.(['tripTime' lat{1}]) = NaN;
    else
        r.(['tripTime' lat{1}]) = trip.Time(k);
        tripped(end + 1) = lat{1}; %#ok<AGROW>
    end
    r.(['classes' lat{1}]) = unique(squeeze(cls.Data))';

    I  = out.logsout.get(['I_' lat{1} 'L']).Values;
    dI = out.logsout.get(['dI_' lat{1} 'L']).Values;
    pre  = I.Time > 0.02 & I.Time < min(o.TEvent, o.StopTime);
    last = I.Time > o.StopTime - 2/60;
    r.(['I' lat{1} 'L_preRMS'])   = max(rms(squeeze(I.Data(pre, :))));
    r.(['I' lat{1} 'L_endRMS'])   = max(rms(squeeze(I.Data(last, :))));
    r.(['dI' lat{1} 'L_endRMS'])  = max(rms(squeeze(dI.Data(last, :))));
end
if isempty(tripped)
    r.tripped = 'none';
else
    r.tripped = char(strjoin(tripped, '+'));
end

% Raw logged waveforms (logged names inside ieee13_hif_twin_system.slx ->
% struct fields), resampled onto the I_650 time base where needed.
r.time = out.logsout.get('I_650').Values.Time;
waves = {
    'I_650_physical', 'I_650';   'I_650_twin', 'twin_I_650';   'dI_650', 'dI_650'
    'I_633_physical', 'I_633L';  'I_633_twin', 'twin_I_633L';  'dI_633', 'dI_633L'
    'I_675_physical', 'I_675L';  'I_675_twin', 'twin_I_675L';  'dI_675', 'dI_675L'
    'trip_633', 'Trip_633';      'trip_675', 'Trip_675'
    'class_633', 'Class_633';    'class_675', 'Class_675'};
for k = 1:size(waves, 1)
    r.(waves{k, 1}) = onTimeBase(out.logsout, waves{k, 2}, r.time);
end
if strcmp(r.scenario, 'hif')
    r.I_arc = onTimeBase(out.logsout, ['I_arc_' bus phase], r.time);
else
    r.I_arc = zeros(size(r.time));
end
r.closeCmd_633 = onTimeBase(out.logsout, 'CloseCmdDelayed_633', r.time);
r.closeCmd_675 = onTimeBase(out.logsout, 'CloseCmdDelayed_675', r.time);
r.breakerDelayCycles = o.BreakerDelayCycles;
r.breakerDelaySteps = delaySteps;
r.interlock = o.Interlock;
if hasInterlock
    r.tripOut_633 = onTimeBase(out.logsout, 'TripOut_633', r.time);
    r.tripOut_675 = onTimeBase(out.logsout, 'TripOut_675', r.time);
else
    r.tripOut_633 = r.trip_633;
    r.tripOut_675 = r.trip_675;
end
end

%% ======================================================================
function y = onTimeBase(logsout, name, t)
% Logged signal as [N x channels] on time base t (zero-order hold if the
% signal was logged at a different rate).
v = logsout.get(name).Values;
y = squeeze(v.Data);
if isrow(y)
    y = y(:);
end
if ~isequal(v.Time, t)
    [tu, ia] = unique(v.Time, 'last');
    y = interp1(tu, y(ia, :), t, 'previous', 'extrap');
end
end

%% ======================================================================
function in = setParams(in, blk, varargin)
% setBlockParameter needs the block path repeated for every name/value pair.
for k = 1:2:numel(varargin)
    in = in.setBlockParameter(blk, varargin{k}, varargin{k + 1});
end
end
