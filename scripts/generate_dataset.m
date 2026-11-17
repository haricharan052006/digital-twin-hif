function generate_dataset(part)
%GENERATE_DATASET  Phase 3: Batch dataset generation for HIF detection via
% digital-twin residual analysis.
%
%   generate_dataset            - main dataset (750 runs) -> data/raw_residuals.mat
%   generate_dataset('boundary') - 150 weak-arc HIF runs near the upper
%                                 strikeable boundary (Vp, Vn 2300-2700 V,
%                                 Rp, Rn 1500-2500 Ohm, 25 per bus/phase,
%                                 rng seed 43) -> data/raw_residuals_boundary.mat.
%                                 extract_features.m appends these to the
%                                 main runs; the main dataset is untouched.
%
% For every scenario this script:
%   1. Builds a Simulink.SimulationInput for ieee13_physical.slx that
%      encodes exactly one event - a healthy load-variation level, a
%      benign switching transient, or an Emanuel-arc HIF on phase A/B/C at
%      edge Bus 633 or Bus 675 - purely through
%      setBlockParameter/setModelParameter overrides. The
%      .slx on disk is never mutated (see the simulating-simulink-models
%      skill: SimulationInput replaces set_param for driving simulations).
%   2. Runs it (parsim if Parallel Computing Toolbox is licensed, sim()
%      otherwise), pulls the 3-phase substation current I_650 and the two
%      lateral-head currents I_633L / I_675L (add_lateral_protection.m) out
%      of logsout, and resamples them onto a common 20 kHz grid.
%   3. Subtracts a SINGLE cached ieee13_digital_twin.slx baseline run - the
%      twin is never randomized (it is the fixed healthy reference), so it
%      only needs to be simulated once for the whole batch - forming the
%      residuals dI(t) = I_physical(t) - I_twin(t) at each metering point,
%      which cancel the nominal load current and isolate the fault/transient
%      signature. The lateral residuals also LOCATE an HIF (633 vs 675).
%   4. Stores the residuals plus the scenario label and full randomized
%      metadata.
%
% HIF arc parameters are sampled from the physically STRIKEABLE range for
% this feeder (Bus 633/675 phase peaks are ~3.0-3.1 kV): Vp 500-2600 V,
% Vn 800-2700 V (~20-85% of bus peak), Rp/Rn 120-2500 Ohm. The full
% CLAUDE.md ranges (Vp to 8 kV, Vn to 10 kV, R to 5 kOhm) left ~50% of HIF
% runs with an arc that never struck - labelled HIF but indistinguishable
% from normal operation. Note Vn's lower bound (800 V) is deliberately
% below the CLAUDE.md minimum of 1000 V. Background load variation during
% HIF runs is held to +/-2% so the residual reflects arc non-linearity
% rather than bulk load change.
%
% Runs are processed in chunks so a crash mid-batch only loses the current
% chunk: a checkpoint .mat is written after each chunk and removed on
% successful completion.
%
% Prerequisite: run scripts/extend_fault_injection.m once first. It adds
% the HIF branches at Buses 633/675 (FaultBreaker_<bus><ph> /
% Emanuel_Arc_Fault_<bus><ph>, e.g. FaultBreaker_633A) and the switchable
% capacitor/load-step branches this script drives (CapBrk_675,
% CapBrk_611C, LoadStepBrk_671) to ieee13_physical.slx.
%
% Breaker "never switches" convention: every breaker held in its no-event
% state uses a far-future switching time '[1e6]'. NEVER '[]': the SPS
% single-phase Breaker inverts its InitialState in discrete mode when
% SwitchingTimes is empty (InitialState '0' + '[]' conducts for the whole
% run - see scripts/verify_emanuel_arc.m), and the Three-Phase Breaker's
% mask errors on an empty SwitchTimes.
%
% Output: data/raw_residuals.mat containing
%   dI       [Nsamples x 3 x Nruns] single    substation residual (A), I_650
%   dI633L   [Nsamples x 3 x Nruns] single    lateral-633 head residual (A), I_633L
%   dI675L   [Nsamples x 3 x Nruns] single    lateral-675 head residual (A), I_675L
%   labels   [Nruns x 1] categorical          Normal | Switching_Transient
%                                              | HIF_Phase_A | HIF_Phase_B | HIF_Phase_C
%   faultBus [Nruns x 1] categorical          633 | 675 for HIF runs, None otherwise
%   tGrid    [Nsamples x 1] double             common time vector (s)
%   meta     [Nruns x 1] struct array          full per-run scenario parameters
%                                              (meta.bus = '633'/'675' for HIF runs)
%   Ts, T_STOP, rngSeed                        for reproducibility
%
% Requires: Simulink, Simscape Electrical (Specialized Power Systems).

%% ============================================================== config
if nargin < 1
    part = 'main';
end

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
modelsDir   = fullfile(projectRoot, 'models');
dataDir     = fullfile(projectRoot, 'data');
if ~exist(dataDir, 'dir')
    mkdir(dataDir);
end
addpath(modelsDir);

physModel = 'ieee13_physical';
twinModel = 'ieee13_digital_twin';

TS     = 50e-6;   % 20 kHz sampling, per CLAUDE.md
T_STOP = 0.30;    % s, per run
T_EVENT_WINDOW = [0.08, T_STOP - 0.05];   % valid window for event/inception time

FAULT_BUSES = {'633', '675'};  % HIF injection edge buses (Review 2 relocation)
HIF_LOAD_DEV = 0.02;           % +/- fraction, background load variation in HIF runs

switch part
    case 'main'
        rngSeed = 42;
        % Scenario counts - reduce these for a quick smoke test before a full run.
        N_NORMAL            = 150;
        N_SWITCHING         = 150;
        N_HIF_PER_BUS_PHASE = 75;     % x2 buses x3 phases = 450 (150 per phase label)
        % Strikeable Emanuel arc ranges (see header).
        ARC_VP = [500, 2600];          % V
        ARC_VN = [800, 2700];          % V  (below the CLAUDE.md 1000 V minimum by choice)
        ARC_R  = [120, 2500];          % Ohm, Rp and Rn
        outName = 'raw_residuals';
    case 'boundary'
        % Weak arcs just inside the strikeable limit (Bus 675 phase A/C
        % peaks are ~2.84 kV): arc peaks down to ~0.05 A. The main ranges
        % had almost no samples here and the relay missed such arcs.
        rngSeed = 43;
        N_NORMAL            = 0;
        N_SWITCHING         = 0;
        N_HIF_PER_BUS_PHASE = 25;     % x2 buses x3 phases = 150
        ARC_VP = [2300, 2700];
        ARC_VN = [2300, 2700];
        ARC_R  = [1500, 2500];
        outName = 'raw_residuals_boundary';
    otherwise
        error('generate_dataset:BadPart', 'part must be ''main'' or ''boundary''.');
end
rng(rngSeed);
fprintf('=== generate_dataset: part "%s" (rng seed %d) ===\n', part, rngSeed);

% Logged 3-phase currents: substation + both lateral heads.
SIGNALS = {'I_650', 'I_633L', 'I_675L'};

CHECKPOINT_CHUNK = 50;    % scenarios per parsim/sim batch + checkpoint save

for f = {[physModel '.slx'], [twinModel '.slx']}
    if ~isfile(fullfile(modelsDir, f{1}))
        error('generate_dataset:ModelMissing', 'models/%s not found.', f{1});
    end
end

%% ------------------------------------------------- validate model extensions
if bdIsLoaded(physModel)
    close_system(physModel, 0);
end
load_system(physModel);
faultBranches = faultBranchTable(FAULT_BUSES);
requiredBlocks = [{faultBranches.breaker}, {faultBranches.arc}, ...
    {'CapBrk_675', 'CapBrk_611C', 'LoadStepBrk_671', 'Tie_671_692', ...
     'Brk_632_633', 'Brk_692_675', 'VI_633L', 'VI_675L'}];
for i = 1:numel(requiredBlocks)
    if getSimulinkBlockHandle([physModel '/' requiredBlocks{i}]) <= 0
        error('generate_dataset:ExtensionMissing', ...
            ['models/%s.slx is missing %s. Run scripts/extend_fault_injection.m ' ...
             'and scripts/add_lateral_protection.m first.'], physModel, requiredBlocks{i});
    end
end

%% ------------------------------------------------------------ load tables
% Spot-load nominal P/Q, verbatim from build_ieee13_network.m. Only the
% constant-PQ/Z/I active loads are listed here (not the capacitor banks,
% which are varied via the switchable breakers instead).
spotLoads = struct('name', {}, 'P', {}, 'Q', {});
spotLoads(end+1) = struct('name', 'L634A',  'P', 160e3, 'Q', 110e3);
spotLoads(end+1) = struct('name', 'L634B',  'P', 120e3, 'Q', 90e3);
spotLoads(end+1) = struct('name', 'L634C',  'P', 120e3, 'Q', 90e3);
spotLoads(end+1) = struct('name', 'L645B',  'P', 170e3, 'Q', 125e3);
spotLoads(end+1) = struct('name', 'L646BC', 'P', 230e3, 'Q', 132e3);
spotLoads(end+1) = struct('name', 'L652A',  'P', 128e3, 'Q', 86e3);
spotLoads(end+1) = struct('name', 'L671AB', 'P', 385e3, 'Q', 220e3);
spotLoads(end+1) = struct('name', 'L671BC', 'P', 385e3, 'Q', 220e3);
spotLoads(end+1) = struct('name', 'L671CA', 'P', 385e3, 'Q', 220e3);
spotLoads(end+1) = struct('name', 'L675A',  'P', 485e3, 'Q', 190e3);
spotLoads(end+1) = struct('name', 'L675B',  'P', 68e3,  'Q', 60e3);
spotLoads(end+1) = struct('name', 'L675C',  'P', 290e3, 'Q', 212e3);
spotLoads(end+1) = struct('name', 'L692CA', 'P', 170e3, 'Q', 151e3);
spotLoads(end+1) = struct('name', 'L611C',  'P', 170e3, 'Q', 80e3);

%% -------------------------------------------------- twin baseline (once)
fprintf('=== Simulating digital-twin baseline (once, %.2f s) ===\n', T_STOP);
tGrid = (0:TS:T_STOP)';
inTwin = Simulink.SimulationInput(twinModel);
inTwin = inTwin.setModelParameter('StopTime', num2str(T_STOP), 'StopFcn', '');
outTwin = sim(inTwin);
iTwinGrid = cell(1, numel(SIGNALS));
for s = 1:numel(SIGNALS)
    iTwinGrid{s} = loggedOnGrid(outTwin.logsout, SIGNALS{s}, tGrid);
end
fprintf('  Twin baseline ready.\n');

%% ------------------------------------------------------- build scenario list
scenarioList = struct('type', {}, 'bus', {}, 'phase', {});
for i = 1:N_NORMAL
    scenarioList(end+1) = struct('type', 'Normal', 'bus', '', 'phase', ''); %#ok<AGROW>
end
for i = 1:N_SWITCHING
    scenarioList(end+1) = struct('type', 'Switching_Transient', 'bus', '', 'phase', ''); %#ok<AGROW>
end
for bus = FAULT_BUSES
    for ph = {'A', 'B', 'C'}
        for i = 1:N_HIF_PER_BUS_PHASE
            scenarioList(end+1) = struct('type', 'HIF', 'bus', bus{1}, 'phase', ph{1}); %#ok<AGROW>
        end
    end
end
scenarioList = scenarioList(randperm(numel(scenarioList)));
Nruns = numel(scenarioList);

%% --------------------------------------------------- build SimulationInputs
metaTemplate = struct('type', '', 'bus', '', 'phase', '', 'loadScale', struct(), ...
    'subtype', '', 'direction', NaN, 'switchTime', NaN, ...
    'Vp', NaN, 'Vn', NaN, 'Rp', NaN, 'Rn', NaN, ...
    'inceptionAngleDeg', NaN, 'tIncept', NaN);

simIn    = repmat(Simulink.SimulationInput(physModel), Nruns, 1);
labelStr = strings(Nruns, 1);
meta     = repmat(metaTemplate, Nruns, 1);

for k = 1:Nruns
    in = baseSimInput(physModel, T_STOP, spotLoads, faultBranches);
    sc = scenarioList(k);
    m = metaTemplate;
    m.type = sc.type;
    m.bus = sc.bus;
    m.phase = sc.phase;

    switch sc.type
        case 'Normal'
            [in, mm] = scenarioNormalLoadVariation(in, spotLoads, physModel);
            m.loadScale = mm.loadScale;
            labelStr(k) = "Normal";

        case 'Switching_Transient'
            [in, mm] = scenarioSwitching(physModel, in, T_EVENT_WINDOW);
            m.subtype = mm.subtype;
            m.direction = mm.direction;
            m.switchTime = mm.switchTime;
            [in, mmL] = scenarioBackgroundLoadVariation(in, spotLoads, physModel, 0.05);
            m.loadScale = mmL.loadScale;
            labelStr(k) = "Switching_Transient";

        case 'HIF'
            [in, mm] = scenarioHIF(physModel, in, sc.bus, sc.phase, faultBranches, ...
                T_EVENT_WINDOW, ARC_VP, ARC_VN, ARC_R);
            m.Vp = mm.Vp; m.Vn = mm.Vn; m.Rp = mm.Rp; m.Rn = mm.Rn;
            m.inceptionAngleDeg = mm.inceptionAngleDeg;
            m.tIncept = mm.tIncept;
            [in, mmL] = scenarioBackgroundLoadVariation(in, spotLoads, physModel, HIF_LOAD_DEV);
            m.loadScale = mmL.loadScale;
            labelStr(k) = "HIF_Phase_" + sc.phase;
    end

    simIn(k) = in;
    meta(k) = m;
end

%% ------------------------------------------------------------- run in chunks
canParallel = false;
try
    canParallel = license('test', 'Distrib_Computing_Toolbox') && ~isempty(ver('parallel'));
catch
    canParallel = false;
end
fprintf('Parallel Computing Toolbox: %s\n', mat2str(canParallel));

Nsamples = numel(tGrid);
dI     = nan(Nsamples, 3, Nruns, 'single');
dI633L = nan(Nsamples, 3, Nruns, 'single');
dI675L = nan(Nsamples, 3, Nruns, 'single');
runOk = false(Nruns, 1);

nChunks = ceil(Nruns / CHECKPOINT_CHUNK);
fprintf('=== Running %d scenarios in %d chunk(s) of up to %d ===\n', ...
    Nruns, nChunks, CHECKPOINT_CHUNK);

ckptFile = fullfile(dataDir, [outName '_checkpoint.mat']);

for c = 1:nChunks
    idx0 = (c - 1) * CHECKPOINT_CHUNK + 1;
    idx1 = min(c * CHECKPOINT_CHUNK, Nruns);
    idxRange = idx0:idx1;

    fprintf('  Chunk %d/%d: scenarios %d-%d ... ', c, nChunks, idx0, idx1);
    chunkIn = simIn(idxRange);
    try
        if canParallel
            chunkOut = parsim(chunkIn, 'ShowProgress', 'off', 'StopOnError', 'off');
        else
            chunkOut = sim(chunkIn, 'StopOnError', 'off');
        end
    catch ME
        warning('generate_dataset:ChunkFailed', ...
            'Chunk %d failed outright (%s); skipping %d scenarios.', ...
            c, ME.message, numel(idxRange));
        continue;
    end

    for j = 1:numel(idxRange)
        k = idxRange(j);
        if ~isempty(chunkOut(j).ErrorMessage)
            warning('generate_dataset:RunFailed', 'Run %d (%s) failed: %s', ...
                k, labelStr(k), chunkOut(j).ErrorMessage);
            continue;
        end
        lg = chunkOut(j).logsout;
        dI(:, :, k)     = single(loggedOnGrid(lg, SIGNALS{1}, tGrid) - iTwinGrid{1});
        dI633L(:, :, k) = single(loggedOnGrid(lg, SIGNALS{2}, tGrid) - iTwinGrid{2});
        dI675L(:, :, k) = single(loggedOnGrid(lg, SIGNALS{3}, tGrid) - iTwinGrid{3});
        runOk(k) = true;
    end
    fprintf('done (%d/%d ok so far)\n', nnz(runOk), idx1);

    save(ckptFile, 'dI', 'dI633L', 'dI675L', 'labelStr', 'runOk', 'meta', 'tGrid', ...
        'TS', 'T_STOP', 'rngSeed', '-v7.3');
end

%% --------------------------------------------------------------- finalize
validCats = ["Normal", "Switching_Transient", "HIF_Phase_A", "HIF_Phase_B", "HIF_Phase_C"];
labels = categorical(labelStr(runOk), validCats);
dI = dI(:, :, runOk);
dI633L = dI633L(:, :, runOk);
dI675L = dI675L(:, :, runOk);
meta = meta(runOk);
busStr = string({meta.bus})';
busStr(busStr == "") = "None";
faultBus = categorical(busStr, ["None", string(FAULT_BUSES)]);
Ts = TS;

outFile = fullfile(dataDir, [outName '.mat']);
save(outFile, 'dI', 'dI633L', 'dI675L', 'labels', 'faultBus', 'tGrid', 'meta', ...
    'Ts', 'T_STOP', 'rngSeed', '-v7.3');

if isfile(ckptFile)
    delete(ckptFile);
end

fprintf('\n=== Done ===\n');
fprintf('  %d/%d scenarios succeeded\n', nnz(runOk), Nruns);
for cat = categories(labels)'
    fprintf('  %-20s %d\n', cat{1}, nnz(labels == cat{1}));
end
for cat = categories(faultBus)'
    fprintf('  bus %-16s %d\n', cat{1}, nnz(faultBus == cat{1}));
end
fprintf('Saved to: %s\n', outFile);
end

%% ======================================================================
function fb = faultBranchTable(faultBuses)
% One entry per HIF branch added by extend_fault_injection.m:
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
% Builds a SimulationInput with every switchable element in its neutral
% "no event" state and all spot loads at nominal - the common starting
% point every scenario overrides on top of.
in = Simulink.SimulationInput(modelName);
% The saved model's StopFcn runs update_live_hif_dashboard after every
% simulation; disable it for batch runs.
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

% Three-Phase Breaker block (Tie_671_692, CapBrk_675, LoadStepBrk_671):
% confirmed via live DialogParameters inspection that its switching-time
% parameter is named 'SwitchTimes' (no "-ing"), unlike the single-phase
% Breaker above. It must never be set to an empty array - the mask
% initialization indexes into SwitchTimes unconditionally and throws
% "Index exceeds array bounds" if it's empty - so '[1e6]' stands in for
% "never switches". Tie_671_692 is held explicitly too: its library-default
% SwitchTimes [1/60 5/60] once islanded Buses 692/675 mid-run.
in = in.setBlockParameter([modelName '/Tie_671_692'], 'External', 'off');
in = in.setBlockParameter([modelName '/Tie_671_692'], 'InitialState', 'closed');
in = in.setBlockParameter([modelName '/Tie_671_692'], 'SwitchTimes', '[1e6]');

% Lateral-head protective breakers (add_lateral_protection.m): closed,
% never tripped while generating training data.
for brk = {'Brk_632_633', 'Brk_692_675'}
    in = in.setBlockParameter([modelName '/' brk{1}], 'External', 'off');
    in = in.setBlockParameter([modelName '/' brk{1}], 'InitialState', 'closed');
    in = in.setBlockParameter([modelName '/' brk{1}], 'SwitchTimes', '[1e6]');
end

in = in.setBlockParameter([modelName '/CapBrk_675'], 'External', 'off');
in = in.setBlockParameter([modelName '/CapBrk_675'], 'InitialState', 'closed');
in = in.setBlockParameter([modelName '/CapBrk_675'], 'SwitchTimes', '[1e6]');

in = in.setBlockParameter([modelName '/LoadStepBrk_671'], 'External', 'off');
in = in.setBlockParameter([modelName '/LoadStepBrk_671'], 'InitialState', 'open');
in = in.setBlockParameter([modelName '/LoadStepBrk_671'], 'SwitchTimes', '[1e6]');
end

%% ======================================================================
function [in, meta] = scenarioNormalLoadVariation(in, spotLoads, modelName)
% Healthy operating condition: every spot load scaled by an independent
% random factor, magnitude uniform in [5%, 15%], random sign.
loadScale = struct();
for i = 1:numel(spotLoads)
    signv = 2 * (rand() < 0.5) - 1;
    mag = 0.05 + 0.10 * rand();
    s = 1 + signv * mag;
    blk = [modelName '/' spotLoads(i).name];
    in = in.setBlockParameter(blk, 'ActivePower', num2str(spotLoads(i).P * s));
    in = in.setBlockParameter(blk, 'InductivePower', num2str(spotLoads(i).Q * s));
    loadScale.(spotLoads(i).name) = s;
end
meta.loadScale = loadScale;
end

%% ======================================================================
function [in, meta] = scenarioBackgroundLoadVariation(in, spotLoads, modelName, maxDev)
% Small background load variation applied under switching/HIF scenarios so
% the classifier does not learn to rely on perfectly nominal loading
% wherever an event is present.
loadScale = struct();
for i = 1:numel(spotLoads)
    signv = 2 * (rand() < 0.5) - 1;
    mag = maxDev * rand();
    s = 1 + signv * mag;
    blk = [modelName '/' spotLoads(i).name];
    in = in.setBlockParameter(blk, 'ActivePower', num2str(spotLoads(i).P * s));
    in = in.setBlockParameter(blk, 'InductivePower', num2str(spotLoads(i).Q * s));
    loadScale.(spotLoads(i).name) = s;
end
meta.loadScale = loadScale;
end

%% ======================================================================
function [in, meta] = scenarioSwitching(modelName, in, T_EVENT_WINDOW)
% Benign switching transient: one of {capacitor bank at 675, capacitor at
% 611, step-load bank at 671} switches once at a random time, in a random
% direction (energize or de-energize).
subtypes = {'cap675', 'cap611', 'loadstep'};
sub = subtypes{randi(3)};
tSwitch = T_EVENT_WINDOW(1) + rand() * (T_EVENT_WINDOW(2) - T_EVENT_WINDOW(1));
direction = randi(2);   % 1 = energize (starts open, closes), 2 = de-energize (starts closed, opens)

switch sub
    case 'cap675'
        % Three-Phase Breaker -> 'SwitchTimes' (no "-ing").
        blk = [modelName '/CapBrk_675'];
        if direction == 1
            in = in.setBlockParameter(blk, 'InitialState', 'open');
        else
            in = in.setBlockParameter(blk, 'InitialState', 'closed');
        end
        in = in.setBlockParameter(blk, 'SwitchTimes', sprintf('[%.6f]', tSwitch));

    case 'cap611'
        % Single-phase Breaker -> 'SwitchingTimes'.
        blk = [modelName '/CapBrk_611C'];
        if direction == 1
            in = in.setBlockParameter(blk, 'InitialState', '0');
        else
            in = in.setBlockParameter(blk, 'InitialState', '1');
        end
        in = in.setBlockParameter(blk, 'SwitchingTimes', sprintf('[%.6f]', tSwitch));

    case 'loadstep'
        % Three-Phase Breaker -> 'SwitchTimes' (no "-ing").
        blk = [modelName '/LoadStepBrk_671'];
        if direction == 1
            in = in.setBlockParameter(blk, 'InitialState', 'open');    % step IN (energize)
        else
            in = in.setBlockParameter(blk, 'InitialState', 'closed');  % step OUT (de-energize)
        end
        in = in.setBlockParameter(blk, 'SwitchTimes', sprintf('[%.6f]', tSwitch));
end

meta.subtype = sub;
meta.direction = direction;
meta.switchTime = tSwitch;
end

%% ======================================================================
function [in, meta] = scenarioHIF(modelName, in, busTag, phaseTag, faultBranches, ...
    T_EVENT_WINDOW, ARC_VP, ARC_VN, ARC_R)
% Emanuel-arc HIF at busTag ('633'/'675') on phaseTag ('A'/'B'/'C'):
% randomized breakdown voltages, arcing/soil resistances, and fault
% inception angle within one 60 Hz cycle, drawn uniformly from the
% strikeable ranges ARC_VP / ARC_VN / ARC_R (see header).
Vp = ARC_VP(1) + diff(ARC_VP) * rand();
Vn = ARC_VN(1) + diff(ARC_VN) * rand();
Rp = ARC_R(1)  + diff(ARC_R)  * rand();
Rn = ARC_R(1)  + diff(ARC_R)  * rand();

tBase = T_EVENT_WINDOW(1) + rand() * (T_EVENT_WINDOW(2) - T_EVENT_WINDOW(1) - 1/60);
inceptionAngleDeg = 360 * rand();
tIncept = tBase + (inceptionAngleDeg / 360) / 60;

fb = faultBranches(strcmp({faultBranches.bus}, busTag) & [faultBranches.phase] == phaseTag);
brk = [modelName '/' fb.breaker];
in = in.setBlockParameter(brk, 'InitialState', '0');
in = in.setBlockParameter(brk, 'SwitchingTimes', sprintf('[%.6f]', tIncept));

arc = [modelName '/' fb.arc];
in = in.setBlockParameter([arc '/Vp'], 'Amplitude', num2str(Vp));
in = in.setBlockParameter([arc '/Vn'], 'Amplitude', num2str(Vn));
in = in.setBlockParameter([arc '/Rp'], 'Resistance', num2str(Rp));
in = in.setBlockParameter([arc '/Rn'], 'Resistance', num2str(Rn));

meta.Vp = Vp; meta.Vn = Vn; meta.Rp = Rp; meta.Rn = Rn;
meta.inceptionAngleDeg = inceptionAngleDeg;
meta.tIncept = tIncept;
end

%% ======================================================================
function yq = loggedOnGrid(logsout, name, tGrid)
% Pulls a logged 3-phase signal out of logsout and resamples it onto tGrid.
sig = logsout.get(name).Values;
y = squeeze(sig.Data);
if isvector(y)
    y = y(:);
end
yq = resampleOnto(sig.Time, y, tGrid);
end

%% ======================================================================
function yq = resampleOnto(t, y, tGrid)
% Interpolates y(t) onto tGrid. Duplicate time stamps (emitted at
% discontinuities such as breaker switching) are collapsed to their last
% value first, since interp1 requires strictly unique sample points.
[tu, ia] = unique(t, 'last');
yq = interp1(tu, y(ia, :), tGrid, 'linear', 'extrap');
end
