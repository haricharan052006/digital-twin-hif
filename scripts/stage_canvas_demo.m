function stage_canvas_demo(scenario, pacingRate, varargin)
%STAGE_CANVAS_DEMO  Prepare ieee13_hif_twin_system.slx for a live,
% press-Run demonstration of the breaker-status lamps on the canvas.
%
%   stage_canvas_demo            % 675A HIF (the saved default), pacing 0.02
%   stage_canvas_demo('633A')    % typical HIF at Bus 633 phase A
%   stage_canvas_demo('675C')    % weak / boundary HIF at Bus 675 phase C
%   stage_canvas_demo('cap675')  % 675 capacitor bank switching (no trip)
%   stage_canvas_demo('healthy') % no event (no trip)
%   stage_canvas_demo(s, rate)   % rate = simulated seconds per wall-clock second
%   stage_canvas_demo(s, rate, 'StopTime', 10, 'TEvent', 3.0, 'SimulationMode', 'accelerator')
%                                % longer staged run / later event / faster mode
%                                % (stage_operator_demo.m uses this)
%
% Then press Run (Ctrl+T) in the Simulink toolbar: the lamps start green
% (CLOSED) and the faulted lateral's lamps turn red (TRIPPED / OPEN) at the
% trip instant - on the top level and next to the breakers inside
% Physical_Feeder and Digital_Twin.
%
% Everything is set IN MEMORY only (fault breaker / arc parameters,
% Simulation Pacing). Do not save the model afterwards; close it with
% close_system('ieee13_hif_twin_system', 0) to discard the staging.
% Simulation Pacing only slows the wall clock - the computed results are
% identical to an unpaced run. Events start at t = 0.10 s (0.05 s for the
% saved default '675A'); runs are 0.30 s.

if nargin < 1
    scenario = '675A';
end
if nargin >= 2 && (ischar(pacingRate) || isstring(pacingRate))
    % stage_canvas_demo(scenario, 'Name', value, ...) - no pacing rate given
    varargin = [{pacingRate}, varargin];
    pacingRate = [];
end
if nargin < 2 || isempty(pacingRate)
    pacingRate = 0.02;   % 0.3 s simulated in ~15 s
end
p = inputParser;
p.addParameter('StopTime', []);         % [] = keep the model's 0.3 s
p.addParameter('TEvent', []);           % [] = 0.10 s (0.05 s for the saved default)
p.addParameter('SimulationMode', '');   % '' = keep the model's (normal)
p.parse(varargin{:});
opt = p.Results;
sysName = 'ieee13_hif_twin_system';
projectRoot = fileparts(fileparts(mfilename('fullpath')));
useLiveProjectPath(projectRoot);
if ~bdIsLoaded(sysName)
    load_system(fullfile(projectRoot, 'models', [sysName '.slx']));
end
feeder = [sysName '/Physical_Feeder'];

% Neutral state: every fault branch dead, decoys in their no-event state
% (switching time 1e6 s; never '[]', which inverts the SPS Breaker).
for bus = {'633', '675'}
    for ph = 'ABC'
        set_param(sprintf('%s/FaultBreaker_%s%s', feeder, bus{1}, ph), ...
            'InitialState', '0', 'SwitchingTimes', '[1e6]');
    end
end
set_param([feeder '/CapBrk_675'], 'InitialState', 'closed', 'SwitchTimes', '[1e6]');

key = upper(char(string(scenario)));
switch key
    case 'HEALTHY'
        desc = 'healthy feeder - lamps stay GREEN';
    case 'CAP675'
        tCap = 0.1;
        if ~isempty(opt.TEvent)
            tCap = opt.TEvent;
        end
        set_param([feeder '/CapBrk_675'], 'SwitchTimes', sprintf('[%g]', tCap));
        desc = sprintf('675 capacitor bank opens at %g s - benign, lamps stay GREEN', tCap);
    otherwise
        tok = regexp(key, '^(633|675)([ABC])$', 'tokens', 'once');
        if isempty(tok)
            error('stage_canvas_demo:BadScenario', ...
                'Scenario must be ''633A''..''675C'', ''cap675'' or ''healthy''.');
        end
        tag = [tok{1} tok{2}];
        tEvent = 0.1;
        arc = struct('Vp', 1500, 'Vn', 2000, 'Rp', 200, 'Rn', 300);
        if strcmp(tag, '675A') && nargin < 1
            tEvent = 0.05;                                  % the saved default
        elseif strcmp(tag, '675C')
            arc = struct('Vp', 2400, 'Vn', 2500, 'Rp', 2000, 'Rn', 2000);   % weak / boundary
        end
        if ~isempty(opt.TEvent)
            tEvent = opt.TEvent;
        end
        set_param([feeder '/FaultBreaker_' tag], 'SwitchingTimes', sprintf('[%g]', tEvent));
        a = [feeder '/Emanuel_Arc_Fault_' tag];
        set_param([a '/Vp'], 'Amplitude', num2str(arc.Vp));
        set_param([a '/Vn'], 'Amplitude', num2str(arc.Vn));
        set_param([a '/Rp'], 'Resistance', num2str(arc.Rp));
        set_param([a '/Rn'], 'Resistance', num2str(arc.Rn));
        desc = sprintf('HIF at Bus %s phase %s from %g s - lateral %s lamps turn RED at the trip', ...
            tok{1}, tok{2}, tEvent, tok{1});
end

if ~isempty(opt.StopTime)
    set_param(sysName, 'StopTime', num2str(opt.StopTime));
end
if ~isempty(opt.SimulationMode)
    set_param(sysName, 'SimulationMode', opt.SimulationMode);
end
set_param(sysName, 'EnablePacing', 'on', 'PacingRate', pacingRate);
open_system(sysName);
open_system(feeder, 'window');

stopTime = str2double(get_param(sysName, 'StopTime'));
fprintf('Staged (in memory, not saved): %s\n', desc);
fprintf('Simulation Pacing on: %.3g simulated s per wall-clock s (%.2f s run >= %.0f s).\n', ...
    pacingRate, stopTime, stopTime / pacingRate);
fprintf('Press Run (Ctrl+T) in the Simulink toolbar. Afterwards discard with:\n');
fprintf('  close_system(''%s'', 0)\n', sysName);
end

%% ======================================================================
function useLiveProjectPath(projectRoot)
% Put this project's live scripts/ and models/ first on the MATLAB path and
% drop any of its backups/ folders: checkpoint copies of these scripts
% (e.g. an older 2-argument stage_canvas_demo) otherwise shadow the live
% ones and cause signature errors.
p = strsplit(path, pathsep);
stale = p(startsWith(p, fullfile(projectRoot, 'backups'), 'IgnoreCase', true));
if ~isempty(stale)
    rmpath(stale{:});
    fprintf('Removed %d backups/ folder(s) from the MATLAB path (they shadow the live scripts).\n', ...
        numel(stale));
end
addpath(fullfile(projectRoot, 'scripts'), fullfile(projectRoot, 'models'));
end
