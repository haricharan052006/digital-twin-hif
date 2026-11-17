function run_live_hif_case(phaseTag, busTag)
%RUN_LIVE_HIF_CASE  Programmatically runs one canonical, reproducible HIF
% scenario on ieee13_physical.slx and triggers the live dashboard - a
% one-click alternative to launch_live_demo.m's "press Run in Simulink"
% interactive workflow.
%
% run_live_hif_case()             - HIF on phase A at Bus 675 (default, a
%                                   fixed, always-identical arcing-fault case).
% run_live_hif_case('B')          - HIF on phase B at Bus 675.
% run_live_hif_case('C', '633')   - HIF on phase C at Bus 633.
%
% HIF branches live at edge Buses 633 and 675 (FaultBreaker_<bus><ph> /
% Emanuel_Arc_Fault_<bus><ph>, added by extend_fault_injection.m).
%
% Every breaker/decoy-branch parameter here is copied VERBATIM from
% generate_dataset.m's baseSimInput() (source of truth re-read from that
% file, not from memory, given how many subtle parameter-name bugs turned
% up in this exact area earlier - e.g. the single-phase Breaker's
% 'SwitchingTimes' vs the Three-Phase Breaker's 'SwitchTimes', and
% Three-Phase Breaker SwitchTimes never being allowed to be empty). Every
% fault breaker except the target branch is held open with a far-future
% switching time '[1e6]' - NOT '[]', which makes the SPS Breaker invert its
% InitialState in discrete mode and conduct for the whole run - and every
% decoy branch (Tie_671_692, CapBrk_675, CapBrk_611C, LoadStepBrk_671) is
% explicitly held in its "no event" state, exactly as baseSimInput leaves
% them.
%
% Unlike generate_dataset.m's randomized sweep, this uses FIXED values for
% a deterministic, always-reproducible demo case:
%   - Arc parameters: Vp=1500 V, Vn=2000 V, Rp=200 Ohm, Rn=300 Ohm - the
%     "typical baseline" documented in CLAUDE.md (~3-3.5 A RMS arc current
%     at Buses 633/675, which sit at ~0.87-0.92 pu without a regulator).
%   - Fault inception time: 0.10 s (comfortably inside generate_dataset.m's
%     own T_EVENT_WINDOW = [0.08, T_STOP-0.05] = [0.08, 0.25] s for
%     T_STOP=0.30 s, leaving a clean pre-fault baseline and 0.20 s of
%     post-fault data to classify/plot).
%   - Spot loads at nominal (no random background variation) - fully
%     deterministic, so this demo case is bit-identical every time it runs.
%
% StopTime is 0.30 s, matching generate_dataset.m's T_STOP exactly - NOT
% the 0.20 s used elsewhere in this project for the unrelated
% add_scopes_and_verify.m / beautify_model_layout.m sanity-check sims.
% Using 0.20 s here would hand the trained classifier a window shorter
% than the one it was trained on, which update_live_hif_dashboard.m
% detects and refuses to classify (a "window too short" warning) rather
% than than produce a misleading result.
%
% After the simulation, this assigns 'out' into the base workspace (so
% update_live_hif_dashboard.m's existing 'out'/'logsout' base-workspace
% lookup finds it, exactly as it would after an interactive Run) and then
% calls update_live_hif_dashboard() directly - no StopFcn involved, since
% this script IS the trigger.
%
% Requires: Simulink, Simscape Electrical (Specialized Power Systems).
% Requires scripts/extend_fault_injection.m to have already been run
% against models/ieee13_physical.slx (adds the Bus 633/675 fault branches
% and decoy branches this script configures).

FAULT_BUSES = {'633', '675'};
if nargin < 1
    phaseTag = 'A';
end
if nargin < 2
    busTag = '675';
end
phaseTag = upper(char(phaseTag));
busTag = char(string(busTag));
if ~ismember(phaseTag, {'A', 'B', 'C'})
    error('run_live_hif_case:BadPhase', 'phaseTag must be ''A'', ''B'', or ''C''.');
end
if ~ismember(busTag, FAULT_BUSES)
    error('run_live_hif_case:BadBus', 'busTag must be ''633'' or ''675''.');
end

projectRoot = fileparts(fileparts(mfilename('fullpath')));
scriptsDir  = fullfile(projectRoot, 'scripts');
modelsDir   = fullfile(projectRoot, 'models');
% Not genpath(projectRoot): that would also put backups/ (stale copies that
% shadow the live scripts and models) and slprj/ caches on the path.
addpath(scriptsDir, modelsDir, fullfile(projectRoot, 'data'));

modelName = 'ieee13_physical';
modelFile = fullfile(modelsDir, [modelName '.slx']);
if ~isfile(modelFile)
    error('run_live_hif_case:ModelMissing', '%s not found.', modelFile);
end

if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
load_system(modelFile);

faultBranches = faultBranchTable(FAULT_BUSES);
requiredBlocks = [{faultBranches.breaker}, {faultBranches.arc}, ...
    {'CapBrk_675', 'CapBrk_611C', 'LoadStepBrk_671', 'Tie_671_692'}];
for i = 1:numel(requiredBlocks)
    if getSimulinkBlockHandle([modelName '/' requiredBlocks{i}]) <= 0
        error('run_live_hif_case:ExtensionMissing', ...
            'models/%s.slx is missing %s. Run scripts/extend_fault_injection.m first.', ...
            modelName, requiredBlocks{i});
    end
end

T_STOP = 0.30;             % matches generate_dataset.m's training window - do not change to 0.20
T_INCEPT = 0.10;           % fixed fault inception time (s)
Vp = 1500; Vn = 2000; Rp = 200; Rn = 300;   % CLAUDE.md "typical baseline" arc parameters

spotLoads = spotLoadTable();

fprintf('=== Configuring %s for a fixed HIF Bus %s Phase %s case (Vp=%d V, Vn=%d V, Rp=%d Ohm, ', ...
    modelName, busTag, phaseTag, Vp, Vn, Rp);
fprintf('Rn=%d Ohm, inception t=%.2f s, StopTime=%.2f s) ===\n', Rn, T_INCEPT, T_STOP);

in = baseSimInput(modelName, T_STOP, spotLoads, faultBranches);

fb = faultBranches(strcmp({faultBranches.bus}, busTag) & [faultBranches.phase] == phaseTag);
brk = [modelName '/' fb.breaker];
in = in.setBlockParameter(brk, 'InitialState', '0');
in = in.setBlockParameter(brk, 'SwitchingTimes', sprintf('[%.6f]', T_INCEPT));

arc = [modelName '/' fb.arc];
in = in.setBlockParameter([arc '/Vp'], 'Amplitude', num2str(Vp));
in = in.setBlockParameter([arc '/Vn'], 'Amplitude', num2str(Vn));
in = in.setBlockParameter([arc '/Rp'], 'Resistance', num2str(Rp));
in = in.setBlockParameter([arc '/Rn'], 'Resistance', num2str(Rn));

fprintf('=== Running (%.2f s) ===\n', T_STOP);
out = sim(in);
fprintf('  Simulation complete.\n');

open_system(modelName);   % visual context for the demo, even though sim() (not the toolbar
                          % Run button / StopFcn) is what actually drove this run

assignin('base', 'out', out);
fprintf('=== Triggering the live dashboard ===\n');
update_live_hif_dashboard();
end

%% ======================================================================
function tbl = spotLoadTable()
% Verbatim from generate_dataset.m.
tbl = struct('name', {}, 'P', {}, 'Q', {});
tbl(end+1) = struct('name', 'L634A',  'P', 160e3, 'Q', 110e3);
tbl(end+1) = struct('name', 'L634B',  'P', 120e3, 'Q', 90e3);
tbl(end+1) = struct('name', 'L634C',  'P', 120e3, 'Q', 90e3);
tbl(end+1) = struct('name', 'L645B',  'P', 170e3, 'Q', 125e3);
tbl(end+1) = struct('name', 'L646BC', 'P', 230e3, 'Q', 132e3);
tbl(end+1) = struct('name', 'L652A',  'P', 128e3, 'Q', 86e3);
tbl(end+1) = struct('name', 'L671AB', 'P', 385e3, 'Q', 220e3);
tbl(end+1) = struct('name', 'L671BC', 'P', 385e3, 'Q', 220e3);
tbl(end+1) = struct('name', 'L671CA', 'P', 385e3, 'Q', 220e3);
tbl(end+1) = struct('name', 'L675A',  'P', 485e3, 'Q', 190e3);
tbl(end+1) = struct('name', 'L675B',  'P', 68e3,  'Q', 60e3);
tbl(end+1) = struct('name', 'L675C',  'P', 290e3, 'Q', 212e3);
tbl(end+1) = struct('name', 'L692CA', 'P', 170e3, 'Q', 151e3);
tbl(end+1) = struct('name', 'L611C',  'P', 170e3, 'Q', 80e3);
end

%% ======================================================================
function fb = faultBranchTable(faultBuses)
% Verbatim from generate_dataset.m: one entry per HIF branch,
%   FaultBreaker_<bus><ph> -> Emanuel_Arc_Fault_<bus><ph> -> FaultGnd_<bus><ph>
fb = struct('bus', {}, 'phase', {}, 'breaker', {}, 'arc', {});
for b = 1:numel(faultBuses)
    for ph = 'ABC'
        tag = [faultBuses{b} ph];
        fb(end+1) = struct('bus', faultBuses{b}, 'phase', ph, ...
            'breaker', ['FaultBreaker_' tag], 'arc', ['Emanuel_Arc_Fault_' tag]); %#ok<AGROW>
    end
end
end

%% ======================================================================
function in = baseSimInput(modelName, T_STOP, spotLoads, faultBranches)
% Verbatim from generate_dataset.m's baseSimInput: every switchable
% element in its neutral "no event" state, all spot loads at nominal.
in = Simulink.SimulationInput(modelName);
% The saved model's StopFcn runs update_live_hif_dashboard after every
% simulation; this script calls it explicitly afterwards instead, so the
% StopFcn is disabled to avoid a second dashboard update.
in = in.setModelParameter('StopTime', num2str(T_STOP), 'StopFcn', '');

for i = 1:numel(spotLoads)
    blk = [modelName '/' spotLoads(i).name];
    in = in.setBlockParameter(blk, 'ActivePower', num2str(spotLoads(i).P));
    in = in.setBlockParameter(blk, 'InductivePower', num2str(spotLoads(i).Q));
end

% Single-phase Breaker block (FaultBreaker_<bus><ph>, CapBrk_611C): its
% switching-time parameter is 'SwitchingTimes'. '[1e6]' = never switches;
% '[]' must not be used - it inverts InitialState (see header).
for i = 1:numel(faultBranches)
    b = [modelName '/' faultBranches(i).breaker];
    in = in.setBlockParameter(b, 'External', 'off');
    in = in.setBlockParameter(b, 'InitialState', '0');
    in = in.setBlockParameter(b, 'SwitchingTimes', '[1e6]');
end

in = in.setBlockParameter([modelName '/CapBrk_611C'], 'External', 'off');
in = in.setBlockParameter([modelName '/CapBrk_611C'], 'InitialState', '1');
in = in.setBlockParameter([modelName '/CapBrk_611C'], 'SwitchingTimes', '[1e6]');

% Three-Phase Breaker block (Tie_671_692, CapBrk_675, LoadStepBrk_671): its
% switching-time parameter is 'SwitchTimes' (no "-ing"), and it must
% never be set to an empty array (mask-init "Index exceeds array bounds")
% - '[1e6]' stands in for "never switches" instead.
in = in.setBlockParameter([modelName '/Tie_671_692'], 'External', 'off');
in = in.setBlockParameter([modelName '/Tie_671_692'], 'InitialState', 'closed');
in = in.setBlockParameter([modelName '/Tie_671_692'], 'SwitchTimes', '[1e6]');

in = in.setBlockParameter([modelName '/CapBrk_675'], 'External', 'off');
in = in.setBlockParameter([modelName '/CapBrk_675'], 'InitialState', 'closed');
in = in.setBlockParameter([modelName '/CapBrk_675'], 'SwitchTimes', '[1e6]');

in = in.setBlockParameter([modelName '/LoadStepBrk_671'], 'External', 'off');
in = in.setBlockParameter([modelName '/LoadStepBrk_671'], 'InitialState', 'open');
in = in.setBlockParameter([modelName '/LoadStepBrk_671'], 'SwitchTimes', '[1e6]');
end
