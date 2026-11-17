%% launch_realtime_demo.m
% Standalone entry point for the TRUE real-time (during-simulation) HIF
% dashboard demo.
%
% This is a separate, additive workflow alongside launch_live_demo.m
% (which does post-run-only classification via StopFcn). This one gives
% you BOTH:
%   - A genuinely real-time, DURING-simulation amplitude-threshold alarm
%     (stream_live_hif_dashboard.m, driven by HIFStreamDashboardBlock - a
%     MATLAB System block wired into ieee13_physical.slx), updating at a
%     decimated ~5 ms cadence as the solver runs.
%   - The EXISTING accurate SVM-based confirmation
%     (update_live_hif_dashboard.m), still firing via StopFcn the moment
%     the run completes, on the SAME shared dashboard window.
% See stream_live_hif_dashboard.m's header comment for why the SVM itself
% cannot meaningfully classify at 5 ms cadence, and why a fast threshold
% + slow confirmation two-stage design is the honest way to deliver
% "real-time fault annunciation" without overselling it.
%
% What this does:
%   1. Adds every project subdirectory to the MATLAB path.
%   2. Ensures models/ieee13_physical.slx has the HIF_Live_Dashboard_Tap
%      block (idempotent - see add_stream_dashboard_block.m; this is the
%      one part of the realtime workflow that IS saved permanently to the
%      .slx, unlike everything else this launcher configures).
%   3. Ensures data/twin_baseline.mat exists (instant if already cached
%      by a previous launch_live_demo.m / launch_realtime_demo.m run;
%      simulated once and cached otherwise).
%   4. Opens the shared dashboard window in its idle "STATUS: NORMAL
%      OPERATION - waiting for a run" state.
%   5. Sets, for THIS SESSION ONLY (via set_param, not saved):
%        - StopFcn -> update_live_hif_dashboard;   (accurate confirmation)
%        - SimulationMode -> 'normal'              (REQUIRED: Accelerator/
%          Rapid Accelerator compile to C and cannot call back into
%          interpreted MATLAB at all - the live dashboard would silently
%          never update under either of those modes)
%        - StopTime -> 0.30 s                      (matches the trained
%          classifier's analysis window)
%   6. Opens the model.
%
% Press Run in the Simulink toolbar - the diagram should react within
% ~5 ms of the residual crossing the fast threshold, and the banner will
% update again with the confirmed SVM verdict the instant the run stops.
%
% Requires: Simulink, Simscape Electrical, Wavelet Toolbox, Statistics
% and Machine Learning Toolbox.

projectRoot = fileparts(mfilename('fullpath'));
modelsDir   = fullfile(projectRoot, 'models');
dataDir     = fullfile(projectRoot, 'data');
% Not genpath(projectRoot): that would also put backups/ (stale copies that
% shadow the live scripts and models) and slprj/ caches on the path.
addpath(fullfile(projectRoot, 'scripts'), modelsDir, dataDir);

modelName = 'ieee13_physical';
modelFile = fullfile(modelsDir, [modelName '.slx']);
if ~isfile(modelFile)
    error('launch_realtime_demo:ModelMissing', '%s not found.', modelFile);
end

twinModelFile = fullfile(modelsDir, 'ieee13_digital_twin.slx');
if ~isfile(twinModelFile)
    error('launch_realtime_demo:TwinModelMissing', '%s not found.', twinModelFile);
end

modelsFile = fullfile(modelsDir, 'trained_classifiers.mat');
if ~isfile(modelsFile)
    error('launch_realtime_demo:ClassifierMissing', ...
        '%s not found. Run scripts/train_classifiers.m first.', modelsFile);
end

if ~exist(dataDir, 'dir')
    mkdir(dataDir);
end

T_STOP = 0.30;   % matches generate_dataset.m's training window

%% -------------------------------------------- 1. attach the live-tap block
fprintf('=== Ensuring the real-time dashboard tap is present in %s ===\n', modelName);
run(fullfile(projectRoot, 'scripts', 'add_stream_dashboard_block.m'));

%% ---------------------------------------- 2. digital-twin baseline cache
twinCacheFile = fullfile(dataDir, 'twin_baseline.mat');
if isfile(twinCacheFile)
    fprintf('\n=== Digital-twin baseline cache found at %s ===\n', twinCacheFile);
    C = load(twinCacheFile, 'T_STOP');
    if abs(C.T_STOP - T_STOP) > 1e-9
        fprintf('  Cache is for a different StopTime - refreshing.\n');
        simulateAndCacheTwinBaseline('ieee13_digital_twin', twinModelFile, T_STOP, twinCacheFile);
    else
        fprintf('  Cache matches the expected %.2f s window - reusing (instant).\n', T_STOP);
    end
else
    fprintf('\n=== No twin baseline cache found - simulating once ===\n');
    simulateAndCacheTwinBaseline('ieee13_digital_twin', twinModelFile, T_STOP, twinCacheFile);
end

%% -------------------------------------------------- 3. idle dashboard
fprintf('\n=== Opening the live streaming dashboard (idle state) ===\n');
stream_live_hif_dashboard('init');

%% ----------------------------------- 4. configure + open the model
fprintf('\n=== Configuring %s for this session ===\n', modelName);
if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
load_system(modelFile);

set_param(modelName, 'StopFcn', 'update_live_hif_dashboard;');
set_param(modelName, 'SimulationMode', 'normal');

currentStopTime = str2double(get_param(modelName, 'StopTime'));
if isnan(currentStopTime) || abs(currentStopTime - T_STOP) > 1e-9
    fprintf('  Setting StopTime %s -> %.2f s (session only, not saved to the .slx).\n', ...
        get_param(modelName, 'StopTime'), T_STOP);
    set_param(modelName, 'StopTime', num2str(T_STOP));
end
fprintf('  StopFcn, SimulationMode=normal, and StopTime set for this session.\n');

open_system(modelName);

fprintf(['\nReady. Press Run in the Simulink toolbar for %s.\n' ...
    'The dashboard reacts in real time (~5 ms cadence) to a fast residual-amplitude\n' ...
    'threshold as the simulation runs, then updates once more with the accurate,\n' ...
    'SVM-confirmed verdict the instant the run stops.\n'], modelName);

%% ======================================================================
function simulateAndCacheTwinBaseline(twinModelName, twinModelFile, T_STOP, cacheFile)
fprintf('  Loading %s ...\n', twinModelFile);
if bdIsLoaded(twinModelName)
    close_system(twinModelName, 0);
end
load_system(twinModelFile);

fprintf('  Simulating %.2f s ...\n', T_STOP);
twinIn = Simulink.SimulationInput(twinModelName);
twinIn = twinIn.setModelParameter('StopTime', num2str(T_STOP));
twinOut = sim(twinIn);
twinSig = twinOut.logsout.get('I_650').Values;
tTwin = twinSig.Time; %#ok<NASGU>
iTwin = squeeze(twinSig.Data); %#ok<NASGU>
save(cacheFile, 'tTwin', 'iTwin', 'T_STOP');
fprintf('  Cached digital-twin I_650 baseline (%d samples) to %s\n', numel(twinSig.Time), cacheFile);
end
