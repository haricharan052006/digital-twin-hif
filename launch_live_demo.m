%% launch_live_demo.m
% Standalone entry point for the live HIF-detection dashboard demo.
%
% What this does:
%   1. Adds the project's models/, scripts/ and data/ folders to the MATLAB
%      path so update_live_hif_dashboard.m (the StopFcn
%      callback target) and both .slx models can be found by name -
%      root-caused fix for the "Model 'ieee13_digital_twin' does not
%      exist" error this used to throw: the earlier version only added
%      scripts/ to the path and never loaded the twin model at all before
%      referencing it by name in a SimulationInput.
%   2. Loads the trained SVM classifier + scaler into the BASE workspace
%      (mdlSVM, scaler, classNames).
%   3. Obtains the digital-twin I_650 baseline and caches it into the base
%      workspace (liveDemo_tTwin / liveDemo_iTwin) - ieee13_physical alone
%      has no "I_twin" signal (the twin is a separate model), so every
%      dashboard update needs this baseline to form the residual. A
%      precomputed copy is read from data/twin_baseline.mat if present
%      (instant); otherwise ieee13_digital_twin.slx is explicitly
%      load_system'd (by full path, not just name resolution) and
%      simulated ONCE, and the result is written to that cache file so
%      every subsequent launch after this one is instant too.
%   4. Opens the live dashboard figure in its idle "Ready / Waiting for
%      Run" state.
%   5. Sets ieee13_physical's StopFcn callback - THIS MATLAB SESSION ONLY,
%      via set_param, NOT saved to the .slx file - and opens the model.
%      The model file on disk, its electrical blocks, line connectivity,
%      and solver/configuration parameters (including StopTime) are all
%      left completely untouched by this launcher.
%
% After running this script, press the Run button in the Simulink
% toolbar for ieee13_physical - the dashboard updates automatically the
% moment that run finishes. See update_live_hif_dashboard.m's header
% comment for exactly what "the moment a run finishes" means here: a
% post-run classification triggered by StopFcn, not a continuous
% during-simulation stream (the trained model needs a full acquired
% window, same acquisition-window property benchmark_latency.m documents).
%
% Requires: Simulink, Simscape Electrical, Wavelet Toolbox, Statistics
% and Machine Learning Toolbox.

projectRoot = fileparts(mfilename('fullpath'));
modelsDir   = fullfile(projectRoot, 'models');
dataDir     = fullfile(projectRoot, 'data');

% Adds models/, scripts/ and data/. Rooted at this script's own folder (not
% pwd) so it works regardless of the current working directory when this
% is run - pwd could be anywhere if the user launched MATLAB from elsewhere
% first. Deliberately NOT genpath(projectRoot): that would also put
% backups/ (stale copies of every script and model, which shadow the live
% ones) and slprj/ build caches on the path.
addpath(fullfile(projectRoot, 'scripts'), modelsDir, dataDir);

modelName = 'ieee13_physical';
modelFile = fullfile(modelsDir, [modelName '.slx']);
if ~isfile(modelFile)
    error('launch_live_demo:ModelMissing', '%s not found.', modelFile);
end

twinModelName = 'ieee13_digital_twin';
twinModelFile = fullfile(modelsDir, [twinModelName '.slx']);
if ~isfile(twinModelFile)
    error('launch_live_demo:TwinModelMissing', '%s not found.', twinModelFile);
end

modelsFile = fullfile(modelsDir, 'trained_classifiers.mat');
if ~isfile(modelsFile)
    error('launch_live_demo:ClassifierMissing', ...
        '%s not found. Run scripts/train_classifiers.m first.', modelsFile);
end

if ~exist(dataDir, 'dir')
    mkdir(dataDir);
end

%% -------------------------------------------------- 1. load classifier
fprintf('=== Loading trained SVM classifier into the base workspace ===\n');
S = load(modelsFile, 'mdlSVM', 'scaler', 'classNames');
mdlSVM = S.mdlSVM; %#ok<NASGU>
scaler = S.scaler; %#ok<NASGU>
classNames = S.classNames; %#ok<NASGU>
fprintf('  mdlSVM, scaler, classNames loaded.\n');

%% ---------------------------------------- 2. digital-twin baseline
T_STOP = 0.30;   % matches generate_dataset.m's training window
twinCacheFile = fullfile(dataDir, 'twin_baseline.mat');

if isfile(twinCacheFile)
    fprintf('=== Loading precomputed digital-twin baseline from %s (instant) ===\n', twinCacheFile);
    C = load(twinCacheFile, 'tTwin', 'iTwin', 'T_STOP');
    if abs(C.T_STOP - T_STOP) < 1e-9
        liveDemo_tTwin = C.tTwin; %#ok<NASGU>
        liveDemo_iTwin = C.iTwin; %#ok<NASGU>
        fprintf('  Loaded cached baseline (%d samples).\n', numel(C.tTwin));
    else
        fprintf(['  Cache is for a %.3f s window, but %.3f s is expected - ' ...
            're-simulating and refreshing the cache.\n'], C.T_STOP, T_STOP);
        [tTwin, iTwin] = simulateAndCacheTwinBaseline(twinModelName, twinModelFile, T_STOP, twinCacheFile);
        liveDemo_tTwin = tTwin; %#ok<NASGU>
        liveDemo_iTwin = iTwin; %#ok<NASGU>
    end
else
    fprintf('=== No precomputed twin baseline found - simulating once and caching for next time ===\n');
    [tTwin, iTwin] = simulateAndCacheTwinBaseline(twinModelName, twinModelFile, T_STOP, twinCacheFile);
    liveDemo_tTwin = tTwin; %#ok<NASGU>
    liveDemo_iTwin = iTwin; %#ok<NASGU>
end

%% -------------------------------------------------- 3. idle dashboard
fprintf('\n=== Opening the live dashboard (idle state) ===\n');
update_live_hif_dashboard('init');

%% ----------------------------------- 4. attach StopFcn + open the model
fprintf('\n=== Attaching StopFcn to %s (this MATLAB session only) ===\n', modelName);
if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
load_system(modelFile);
set_param(modelName, 'StopFcn', 'update_live_hif_dashboard;');

currentStopTime = str2double(get_param(modelName, 'StopTime'));
if isnan(currentStopTime) || abs(currentStopTime - T_STOP) > 1e-9
    fprintf(['\nNOTE: %s''s current StopTime is %s s; the trained classifier expects a ' ...
        '%.2f s analysis window (matching generate_dataset.m). Setting it to %.2f s for ' ...
        'this session (via set_param, not saved to the .slx file - the model file on disk, ' ...
        'its electrical blocks, and its line connectivity remain untouched; only the live, ' ...
        'in-memory StopTime for this demo session changes).\n\n'], ...
        modelName, get_param(modelName, 'StopTime'), T_STOP, T_STOP);
    set_param(modelName, 'StopTime', num2str(T_STOP));
end

open_system(modelName);

fprintf(['Ready. Press the Run button in the Simulink toolbar for %s - the dashboard ' ...
    'updates automatically when the run finishes.\n' ...
    '(StopFcn is set for this MATLAB session only; %s on disk is untouched - its blocks, ' ...
    'connectivity, and solver settings are unchanged.)\n'], modelName, [modelName '.slx']);

%% ======================================================================
function [t, y] = simulateAndCacheTwinBaseline(twinModelName, twinModelFile, T_STOP, cacheFile)
% Explicitly load_system's the twin by its full file path (not just name
% resolution via the MATLAB path) before referencing it in a
% SimulationInput - this is the actual fix for "Model 'ieee13_digital_twin'
% does not exist": SimulationInput needs the model name to resolve to an
% already-loaded (or path-resolvable) model, and the previous version of
% this launcher never loaded it and never added models/ to the path.
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
t = twinSig.Time;
y = squeeze(twinSig.Data);

tTwin = t; %#ok<NASGU>
iTwin = y; %#ok<NASGU>
save(cacheFile, 'tTwin', 'iTwin', 'T_STOP');
fprintf('  Cached digital-twin I_650 baseline (%d samples) to %s\n', numel(t), cacheFile);
end
