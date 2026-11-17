function stage_operator_demo(scenario, varargin)
%STAGE_OPERATOR_DEMO  Stage the 10-second interactive operator-control demo
% on ieee13_hif_twin_system.slx, ready to press Run.
%
%   stage_operator_demo                 % 633A HIF at t = 3.0 s, Auto mode
%   stage_operator_demo('675C')         % weak HIF at Bus 675 phase C
%   stage_operator_demo('633A', 'Mode', 'Manual')   % start in Manual mode
%
% Name-value options:
%   'StopTime'       run length, s                      (default 10)
%   'TFault'         HIF inception / switching time, s  (default 3.0)
%   'Mode'           'Auto' | 'Manual' starting position of Control_Mode
%   'ManualTrip633'  'Closed' | 'Trip' starting position of Manual_Trip_633
%                    (breaker 632-633)
%   'ManualTrip675'  'Closed' | 'Trip' starting position of Manual_Trip_675
%                    (breaker 692-675)
%   'PacingRate'     simulated s per wall-clock s       (default 1 = real time)
%   'SimulationMode' 'accelerator' (default) | 'normal'
%
% Timeline: 0 - TFault healthy baseline (lamps GREEN, flat residuals);
% at TFault the Emanuel arc ignites on the chosen bus/phase and persists
% until the lateral breaker opens. In Auto the ML relay trips it (~17 ms
% later for 633A, ~60 ms for the weak 675C arc); in Manual the arc keeps
% burning until the operator flips that lateral's toggle (Manual_Trip_633
% or Manual_Trip_675) to "Isolate / Trip", which opens only that lateral's
% breaker, feeder and twin; the other lateral stays in service. Flipping
% Control_Mode back to Auto hands control back to the relays (a relay that
% already latched a trip opens its breaker immediately).
%
% Everything is set IN MEMORY only (stop time, fault time, simulation mode,
% pacing, switch positions, scope time span) - the solver (discrete,
% Ts = 50e-6 s) is unchanged. Do not save the model afterwards; discard
% with close_system('ieee13_hif_twin_system', 0).
%
% Speed: the model computes slower than real time. Accelerator mode is
% ~3x faster than Normal with bit-identical results; Pacing only caps the
% speed (it can slow a run down, never speed it up), so at PacingRate 1 a
% 10 s run takes max(10 s, the model's compute time). If the dashboard
% lamps or switches do not respond in Accelerator mode on your setup, use
% 'SimulationMode', 'normal' (slower).

if nargin < 1
    scenario = '633A';
end
p = inputParser;
p.addParameter('StopTime', 10);
p.addParameter('TFault', 3.0);
p.addParameter('Mode', 'Auto');
p.addParameter('ManualTrip633', 'Closed');
p.addParameter('ManualTrip675', 'Closed');
p.addParameter('PacingRate', 1);
p.addParameter('SimulationMode', 'accelerator');
p.parse(varargin{:});
o = p.Results;
sysName = 'ieee13_hif_twin_system';

% Make sure the stage_canvas_demo called below is the live one next to this
% file - not a checkpoint copy under backups/ (an older 2-argument version
% there caused "Too many input arguments").
scriptDir = fileparts(mfilename('fullpath'));
pathEntries = strsplit(path, pathsep);
stale = pathEntries(startsWith(pathEntries, fullfile(fileparts(scriptDir), 'backups'), 'IgnoreCase', true));
if ~isempty(stale)
    rmpath(stale{:});
    fprintf('Removed %d backups/ folder(s) from the MATLAB path (they shadow the live scripts).\n', ...
        numel(stale));
end
addpath(scriptDir);
resolved = which('stage_canvas_demo');
if ~strcmpi(resolved, fullfile(scriptDir, 'stage_canvas_demo.m'))
    error('stage_operator_demo:Shadowed', ...
        'stage_canvas_demo resolves to %s instead of %s - remove that folder from the path.', ...
        resolved, fullfile(scriptDir, 'stage_canvas_demo.m'));
end

stage_canvas_demo(scenario, o.PacingRate, 'StopTime', o.StopTime, 'TEvent', o.TFault, ...
    'SimulationMode', o.SimulationMode);

modeValue = double(strcmpi(o.Mode, 'Auto'));
trip633 = double(strcmpi(o.ManualTrip633, 'Closed'));
trip675 = double(strcmpi(o.ManualTrip675, 'Closed'));
set_param([sysName '/Control_Mode'], 'Value', num2str(modeValue));
set_param([sysName '/Manual_Trip_633'], 'Value', num2str(trip633));
set_param([sysName '/Manual_Trip_675'], 'Value', num2str(trip675));

% Scope time spans cover the whole run (display only).
cfg = get_param([sysName '/Scope_Isolated_Current'], 'ScopeConfiguration');
cfg.TimeSpan = num2str(o.StopTime);
for s = {'Scope_Residuals', 'Scope_Relays'}
    c = get_param([sysName '/' s{1}], 'ScopeConfiguration');
    c.TimeSpan = num2str(o.StopTime);
end
open_system([sysName '/Scope_Isolated_Current']);
open_system([sysName '/Scope_Relays']);

modeText = {'Manual', 'Auto'};
tripText = {'Isolate / Trip', 'Normal / Closed'};
fprintf('Operator controls start at: Control_Mode = %s, Manual_Trip_633 = %s, Manual_Trip_675 = %s\n', ...
    modeText{modeValue + 1}, tripText{trip633 + 1}, tripText{trip675 + 1});
fprintf('Simulation mode: %s, StopTime %g s, fault at %g s.\n', o.SimulationMode, o.StopTime, o.TFault);
fprintf(['Press Run (Ctrl+T). Flip the Control_Mode / Manual_Trip_633 / Manual_Trip_675 ' ...
    'toggles on the canvas during the run.\n']);
end
