%% add_stream_dashboard_block.m
% Idempotently adds a real-time dashboard visualization tap
% (HIFStreamDashboardBlock, a MATLAB System block) to
% models/ieee13_physical.slx, branched off the EXISTING VI_650 current
% measurement - exactly the same non-invasive "branch off an existing
% signal" pattern add_scopes_and_verify.m's attachSinks uses for its
% Scope/ToWorkspace sinks, so this cannot disturb the existing electrical
% network, I_650/I_arc logging, or any of the switchable fault/decoy
% branches. A Clock block is added alongside to feed it simulation time.
%
% UNLIKE every other model-editing script in this project so far, this
% one SAVES the addition permanently to ieee13_physical.slx (not
% session-only) - because the request that produced this file explicitly
% asked for the block to be added "into models/ieee13_physical.slx", not
% attached as a session-scoped callback. This creates a NEW, real
% dependency: the model file can no longer be opened/compiled without
% scripts/HIFStreamDashboardBlock.m and scripts/stream_live_hif_dashboard.m
% on the MATLAB path. models/ieee13_physical_backup.slx (from
% beautify_model_layout.m, if that was ever run) or your own version
% control is the way back if this ever needs reverting.
%
% Requires: Simulink. scripts/HIFStreamDashboardBlock.m and
% scripts/stream_live_hif_dashboard.m must be on the MATLAB path (ensured
% by launch_realtime_demo.m's addpath) for the model to load/simulate
% correctly after this runs.

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
modelsDir   = fullfile(projectRoot, 'models');

modelName = 'ieee13_physical';
modelFile = fullfile(modelsDir, [modelName '.slx']);
if ~isfile(modelFile)
    error('add_stream_dashboard_block:ModelMissing', '%s not found.', modelFile);
end

if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
load_system(modelFile);

blockName = 'HIF_Live_Dashboard_Tap';
clockName = 'HIF_Dashboard_Clock';
blockPath = [modelName '/' blockName];
clockPath = [modelName '/' clockName];

needsSave = false;

if getSimulinkBlockHandle(blockPath) > 0
    fprintf('%s already present in %s.\n', blockPath, modelName);
else
    if exist('HIFStreamDashboardBlock', 'class') ~= 8
        error('add_stream_dashboard_block:ClassNotFound', ...
            ['HIFStreamDashboardBlock (scripts/HIFStreamDashboardBlock.m) is not on the ' ...
             'MATLAB path. addpath the scripts/ directory (launch_realtime_demo.m does this) ' ...
             'before running this script.']);
    end
    if getSimulinkBlockHandle([modelName '/VI_650']) <= 0
        error('add_stream_dashboard_block:VI650Missing', ...
            'VI_650 not found in %s - run scripts/add_scopes_and_verify.m first.', modelName);
    end
    ph = get_param([modelName '/VI_650'], 'PortHandles');
    if numel(ph.Outport) ~= 1
        error('add_stream_dashboard_block:UnexpectedViPorts', ...
            'VI_650 exposes %d signal outports; expected exactly 1 (Iabc).', numel(ph.Outport));
    end

    % A matlab.System classdef is NOT itself a valid add_block source
    % reference ("HIFStreamDashboardBlock" is a class name, not a library
    % block path) - that mismatch is what actually produced the "no block
    % named..." / "'' is not a valid model name" error. The correct,
    % standard mechanism is to add Simulink's library 'MATLAB System'
    % block, then bind it to the class via its 'System' parameter.
    add_block('simulink/User-Defined Functions/MATLAB System', blockPath, ...
        'Position', nextSlot(modelName));
    set_param(blockPath, 'System', 'HIFStreamDashboardBlock');

    add_block('simulink/Sources/Clock', clockPath, 'Position', nextSlot(modelName));

    add_line(modelName, 'VI_650/1', [blockName '/1'], 'autorouting', 'on');
    add_line(modelName, [clockName '/1'], [blockName '/2'], 'autorouting', 'on');

    fprintf('Added %s (+ %s) to %s.\n', blockPath, clockPath, modelFile);
    needsSave = true;
end

% ALWAYS verify/enforce interpreted execution, whether the block was just
% added above or was already present from an earlier run of this script
% (i.e. from before this fix existed). A 'MATLAB System' block can default
% to attempting CODE GENERATION, which imposes MATLAB Coder's static
% analysis restrictions (e.g. the "persistent variable must be assigned
% before it is used" error this fixes) - restrictions
% stream_live_hif_dashboard.m was never written to satisfy, since it
% calls ordinary interpreted-only MATLAB throughout (figure, timer,
% containers.Map, dynamic struct fields). Interpreted execution runs the
% actual M-code directly with no such restrictions - the only correct fix
% here, not a workaround via coder.extrinsic (which only exempts
% individual function CALLS from code generation, not the persistent-
% variable control-flow analysis applied to the surrounding code itself).
currentMode = get_param(blockPath, 'SimulateUsing');
if ~strcmp(currentMode, 'Interpreted execution')
    set_param(blockPath, 'SimulateUsing', 'Interpreted execution');
    fprintf('  Set %s SimulateUsing: %s -> Interpreted execution\n', blockPath, currentMode);
    needsSave = true;
end

if needsSave
    save_system(modelName, modelFile);
    fprintf('Saved %s.\n', modelFile);
else
    fprintf('Nothing to change.\n');
end

close_system(modelName, 0);

%% ======================================================================
function pos = nextSlot(modelName)
% Same free-strip positioning helper used by extend_fault_injection.m, so
% new blocks never land on top of the existing arranged layout.
persistent slot
if isempty(slot)
    slot = 0;
end
blks = find_system(modelName, 'SearchDepth', 1, 'Type', 'Block');
minX = 50; maxY = 50;
for i = 1:numel(blks)
    if strcmp(blks{i}, modelName)
        continue;
    end
    p = get_param(blks{i}, 'Position');
    minX = min(minX, p(1));
    maxY = max(maxY, p(4));
end
slot = slot + 1;
col = mod(slot - 1, 10);
row = floor((slot - 1) / 10);
x = minX + col * 90;
y = maxY + 120 + row * 90;
pos = [x, y, x + 55, y + 35];
end
