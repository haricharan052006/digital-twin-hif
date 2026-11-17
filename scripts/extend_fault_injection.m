%% extend_fault_injection.m
% Phase 3 prep: extends models/ieee13_physical.slx (additively, idempotently
% - never rebuilds the verified network) with the switchable branches
% generate_dataset.m needs to sweep HIF phase and benign switching events
% purely through Simulink.SimulationInput block-parameter overrides:
%
%   1. Review 2 Goal 1 - HIF fault relocation to the feeder edge buses.
%      The legacy Bus 671 HIF branches (FaultBreaker_671/671B/671C,
%      Emanuel_Arc_Fault/FaultB/FaultC, FaultGnd/GndB/GndC - phase A built
%      by build_ieee13_network.m, B/C by earlier versions of this script)
%      are REMOVED, and a full phase A/B/C set of Emanuel-arc HIF branches
%      is added at each of Bus 633 and Bus 675:
%        FaultBreaker_<bus><ph> -> Emanuel_Arc_Fault_<bus><ph> -> FaultGnd_<bus><ph>
%      e.g. FaultBreaker_633A -> Emanuel_Arc_Fault_633A -> FaultGnd_633A.
%      Bus 633 (4.16 kV primary of XFM_633_634) is used instead of Bus 634:
%      634 is the 0.48 kV secondary (~392 V phase peak), below the CLAUDE.md
%      minimum arc breakdown Vp = 500 V, so an arc there would never strike.
%      Each arc copy's inherited I_arc instrumentation (ToWs_I_arc variable
%      and the logged I_arc port) is renamed I_arc_<bus><ph> so the six
%      copies no longer collide on the shared 'I_arc' name.
%      These six branches are deleted and re-created on EVERY run, so the
%      arc copies always match the current emanuel_arc_subsystem.slx (e.g.
%      after the 1 MOhm resistive diode-snubber fix in build_emanuel_arc.m).
%
%      SPS Breaker trap (verified by verify_emanuel_arc.m): InitialState
%      '0' with an EMPTY SwitchingTimes '[]' is NOT open in discrete mode -
%      the block inverts its initial state when it has no switching times,
%      so the branch conducts for the whole run. Dead breakers therefore use
%      a far-future switching time, '[1e6]', never '[]'.
%
%   2. A gang-switched breaker in series with the Bus 675 capacitor bank
%      (CapBrk_675, all 3 phases together) and a single-phase breaker in
%      series with the Bus 611 phase-C capacitor (CapBrk_611C), so a
%      capacitor bank can be energized/de-energized mid-run to synthesize
%      a capacitor-switching transient.
%
%   3. A gang-switched step-load bank at Bus 671 (LoadStepBrk_671 +
%      LoadStepA/B/C_671, Y-connected, 80 kW / 40 kVAr per phase) that is
%      normally out of circuit, for synthesizing benign step-load-change
%      transients.
%
%   4. Steady-state breaker defaults, enforced on every run (not only when
%      a block is first created): Tie_671_692, CapBrk_675 and
%      LoadStepBrk_671 had been left at the Three-Phase Breaker library
%      default SwitchTimes [1/60 5/60] - switching at 16.7 ms and 83.3 ms
%      of every run (the tie islanded Buses 692/675) - and CapBrk_611C
%      used the inverting empty SwitchingTimes.
%
% Saved-model defaults (generate_dataset.m overrides per scenario):
%   - FaultBreaker_675A defaults to CLOSING at t = 0.05 s (takes over the
%     legacy FaultBreaker_671's role as the model's default armed HIF, so
%     an unmodified run still shows a fault). Every other FaultBreaker_633*
%     / 675* defaults OPEN until t = 1e6 s -> dead branches.
%   - Tie_671_692, CapBrk_675 and CapBrk_611C are permanently CLOSED
%     (switching time 1e6 s) -> tie and capacitor banks in service.
%   - LoadStepBrk_671 is permanently OPEN (switching time 1e6 s) -> the
%     step-load bank contributes nothing.
% generate_dataset.m is the only place any of this is overridden, and it
% does so per-scenario via Simulink.SimulationInput.setBlockParameter, not
% by mutating the saved model - see the simulating-simulink-models skill
% guardrails (SimulationInput replaces set_param for driving simulations).
%
% Re-running this script is safe: the 633/675 HIF branches are rebuilt,
% the breaker defaults are re-applied, and every other add_block/add_line
% is guarded by a getSimulinkBlockHandle check.
%
% Bus-tap reference points (verified against scripts/build_ieee13_network.m,
% NOT re-derived live): Line_632_671 is the feeder segment from Bus 632 to
% Bus 671 (lineSegs table), so its RConn1/RConn2/RConn3 are Bus 671
% phases A/B/C - the same three ports build_ieee13_network.m used to wire
% Tie_671_692, the phase-671 delta loads, and the existing FaultBreaker_671
% (phase A, via RConn1). Likewise Line_692_675 -> Bus 675 A/B/C, and
% Line_684_611 -> Bus 611 (only RConn3 / phase C is loaded there).
%
% Requires: Simulink, Simscape Electrical (Specialized Power Systems).

%% ---------------------------------------------------------------- setup
scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
modelsDir   = fullfile(projectRoot, 'models');

modelName = 'ieee13_physical';
modelFile = fullfile(modelsDir, [modelName '.slx']);
arcModel  = 'emanuel_arc_subsystem';
arcFile   = fullfile(modelsDir, [arcModel '.slx']);

if ~isfile(modelFile)
    error('extend_fault_injection:ModelMissing', ...
        'models/%s.slx not found. Run build_ieee13_network.m first.', modelName);
end
if ~isfile(arcFile)
    error('extend_fault_injection:ArcModelMissing', ...
        'models/%s.slx not found. Run build_emanuel_arc.m first.', arcModel);
end

libRoot = locateSpsLibrary();
faultBreakerBlk = [libRoot '/Power Grid Elements/Breaker'];
tieBreakerBlk   = [libRoot '/Power Grid Elements/Three-Phase Breaker'];
rlcLoadBlk      = [libRoot '/Passives/Series RLC Load'];
groundBlk       = [libRoot '/Utilities/Ground'];

if bdIsLoaded(arcModel)
    close_system(arcModel, 0);
end
load_system(arcFile);

if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
load_system(modelFile);

%% ------------------------------------------------- locate bus phase taps
if getSimulinkBlockHandle([modelName '/Line_632_671']) <= 0
    error('extend_fault_injection:Bus671NotFound', ...
        'Line_632_671 not found in %s; cannot locate Bus 671 phase taps.', modelName);
end
bus671 = {'Line_632_671/RConn1', 'Line_632_671/RConn2', 'Line_632_671/RConn3'};

% Line_632_633's far end is Bus 633 (its RConn ports feed XFM_633_634's
% 4.16 kV side).
if getSimulinkBlockHandle([modelName '/Line_632_633']) <= 0
    error('extend_fault_injection:Bus633NotFound', ...
        'Line_632_633 not found in %s; cannot locate Bus 633 phase taps.', modelName);
end
bus633 = {'Line_632_633/RConn1', 'Line_632_633/RConn2', 'Line_632_633/RConn3'};

if getSimulinkBlockHandle([modelName '/Line_692_675']) <= 0
    error('extend_fault_injection:Bus675NotFound', ...
        'Line_692_675 not found in %s; cannot locate Bus 675 phase taps.', modelName);
end
bus675 = {'Line_692_675/RConn1', 'Line_692_675/RConn2', 'Line_692_675/RConn3'};

if getSimulinkBlockHandle([modelName '/Line_684_611']) <= 0
    error('extend_fault_injection:Bus611NotFound', ...
        'Line_684_611 not found in %s; cannot locate the Bus 611 phase-C tap.', modelName);
end
bus611C = 'Line_684_611/RConn3';

fprintf('=== Extending %s.slx ===\n', modelName);

%% ------------- 1. Relocate HIF fault injection: Bus 671 -> Buses 633, 675
legacyFaultBlocks = {'FaultBreaker_671', 'FaultBreaker_671B', 'FaultBreaker_671C', ...
    'Emanuel_Arc_Fault', 'Emanuel_Arc_FaultB', 'Emanuel_Arc_FaultC', ...
    'FaultGnd', 'FaultGndB', 'FaultGndC'};
nRemoved = removeBlocksWithLines(modelName, legacyFaultBlocks);
fprintf('  Removed %d legacy Bus 671 HIF fault blocks\n', nRemoved);

faultBuses = struct('bus', {'633', '675'}, 'ports', {bus633, bus675});
phaseTags = 'ABC';

% Drop any existing 633/675 branches so they are rebuilt from the current
% emanuel_arc_subsystem.slx below.
staleBranchBlocks = {};
for b = 1:numel(faultBuses)
    for k = 1:3
        tag = [faultBuses(b).bus phaseTags(k)];
        staleBranchBlocks = [staleBranchBlocks, {['FaultBreaker_' tag], ...
            ['Emanuel_Arc_Fault_' tag], ['FaultGnd_' tag]}]; %#ok<AGROW>
    end
end
nRemoved = removeBlocksWithLines(modelName, staleBranchBlocks);
fprintf('  Removed %d existing Bus 633/675 HIF branch blocks (rebuilding)\n', nRemoved);

for b = 1:numel(faultBuses)
    for k = 1:3
        tag = [faultBuses(b).bus phaseTags(k)];
        % FaultBreaker_675A is the model's default armed HIF (closes at
        % 0.05 s, the legacy FaultBreaker_671 default); all others are dead
        % until a far-future time (never '[]' - see header).
        if strcmp(tag, '675A')
            switchTimes = '[0.05]';
        else
            switchTimes = '[1e6]';
        end
        addFaultBranch(modelName, faultBreakerBlk, groundBlk, ...
            faultBuses(b).ports{k}, tag, switchTimes);
    end
end
fprintf(['  HIF fault branches: FaultBreaker_<bus><ph> + Emanuel_Arc_Fault_<bus><ph>' ...
    ' + FaultGnd_<bus><ph> for buses 633/675, phases A/B/C\n']);

%% ------------------- 2. Switchable capacitor banks (675 gang, 611 phase C)
insertCapBreaker3ph(modelName, tieBreakerBlk, bus675, ...
    {'Cap675A', 'Cap675B', 'Cap675C'}, 'CapBrk_675');
insertCapBreaker1ph(modelName, faultBreakerBlk, bus611C, 'Cap611C', 'CapBrk_611C');
fprintf('  Switchable capacitor banks: CapBrk_675 (gang, 3-phase), CapBrk_611C\n');

%% --------------------- 3. Switchable step-load bank at Bus 671 (Y, 80kW/40kVAr)
addLoadStepBank(modelName, tieBreakerBlk, rlcLoadBlk, groundBlk, bus671, ...
    'LoadStepBrk_671', 'LoadStep', 80e3, 40e3);
fprintf('  Switchable step-load bank: LoadStepBrk_671 + LoadStepA/B/C_671\n');

%% ----------------------- 4. Steady-state breaker defaults (every run)
% Three-Phase Breaker uses 'SwitchTimes' with an 'open'/'closed' state;
% the single-phase Breaker uses 'SwitchingTimes' with '0'/'1'.
set_param([modelName '/Tie_671_692'], 'External', 'off', ...
    'InitialState', 'closed', 'SwitchTimes', '[1e6]');
set_param([modelName '/CapBrk_675'], 'External', 'off', ...
    'InitialState', 'closed', 'SwitchTimes', '[1e6]');
set_param([modelName '/LoadStepBrk_671'], 'External', 'off', ...
    'InitialState', 'open', 'SwitchTimes', '[1e6]');
set_param([modelName '/CapBrk_611C'], 'External', 'off', ...
    'InitialState', '1', 'SwitchingTimes', '[1e6]');
fprintf(['  Breaker defaults: Tie_671_692/CapBrk_675/CapBrk_611C closed, ' ...
    'LoadStepBrk_671 open, all switching at t = 1e6 s (never)\n']);

%% --------------------------------------------------------------- save
save_system(modelName, modelFile);
close_system(modelName, 0);
close_system(arcModel, 0);

fprintf('\n%s.slx extended and saved to: %s\n', modelName, modelFile);
fprintf('ieee13_digital_twin.slx is untouched - it stays the fixed healthy baseline.\n');

%% ======================================================================
function addFaultBranch(modelName, faultBreakerBlk, groundBlk, busPortSpec, tag, switchTimes)
% Adds one phase-injection HIF branch at busPortSpec, tag = '<bus><phase>':
%   FaultBreaker_<tag> -> Emanuel_Arc_Fault_<tag> -> FaultGnd_<tag>
% InitialState is open; switchTimes '[1e6]' leaves the branch dead (zero
% current) until generate_dataset.m commands it via a SimulationInput
% override ('[]' would invert to closed - see header). Idempotent.

brkName = ['FaultBreaker_' tag];
arcName = ['Emanuel_Arc_Fault_' tag];
gndName = ['FaultGnd_' tag];

brkPath = [modelName '/' brkName];
if getSimulinkBlockHandle(brkPath) > 0
    return;   % already added
end

add_block(faultBreakerBlk, brkPath, 'Position', nextSlot(modelName));
% External MUST be off (see build_ieee13_network.m FaultBreaker_671 notes):
% the SPS Breaker block defaults to external control of switching times,
% which silently ignores SwitchingTimes and holds the breaker open forever.
set_param(brkPath, 'External', 'off', 'InitialState', '0', 'SwitchingTimes', switchTimes);

arcPath = [modelName '/' arcName];
add_block('emanuel_arc_subsystem/Emanuel_Arc_Fault', arcPath, ...
    'Position', nextSlot(modelName));
renameArcInstrumentation(arcPath, ['I_arc_' tag]);

add_block(groundBlk, [modelName '/' gndName], 'Position', nextSlot(modelName));

add_line(modelName, busPortSpec, [brkName '/LConn1'], 'autorouting', 'on');
add_line(modelName, [brkName '/RConn1'], [arcName '/LConn1'], 'autorouting', 'on');
add_line(modelName, [arcName '/LConn2'], [gndName '/LConn1'], 'autorouting', 'on');
end

%% ======================================================================
function renameArcInstrumentation(arcPath, varName)
% Each Emanuel_Arc_Fault copy inherits emanuel_arc_subsystem.slx's
% instrumentation (add_scopes_and_verify.m): a ToWs_I_arc sink with
% VariableName 'I_arc' and a logged I_arc measurement port named 'I_arc'.
% Six copies sharing those names collide ("Duplicate data logging variable
% name"), so both are renamed to a per-branch varName (e.g. I_arc_675A).
towsPath = [arcPath '/ToWs_I_arc'];
if getSimulinkBlockHandle(towsPath) > 0
    set_param(towsPath, 'VariableName', varName);
end
loggedPorts = find_system(arcPath, 'FindAll', 'on', 'LookUnderMasks', 'all', ...
    'Type', 'port', 'DataLogging', 'on');
for i = 1:numel(loggedPorts)
    set_param(loggedPorts(i), 'DataLoggingNameMode', 'Custom', ...
        'DataLoggingName', varName);
end
end

%% ======================================================================
function nRemoved = removeBlocksWithLines(modelName, blockNames)
% Deletes each named top-level block together with the connection lines on
% its own ports. Deleting a block's own line handles removes only that
% block's branch of a shared bus node - the other loads/lines tapped off
% the same bus port stay connected. Missing blocks are skipped
% (idempotent).
nRemoved = 0;
for i = 1:numel(blockNames)
    blkPath = [modelName '/' blockNames{i}];
    if getSimulinkBlockHandle(blkPath) <= 0
        continue;
    end
    lh = get_param(blkPath, 'LineHandles');
    h = [lh.LConn(:); lh.RConn(:)];
    h = h(h > 0);
    for k = 1:numel(h)
        if ishandle(h(k))
            delete_line(h(k));
        end
    end
    delete_block(blkPath);
    nRemoved = nRemoved + 1;
end
end

%% ======================================================================
function insertCapBreaker3ph(modelName, tieBreakerBlk, busPortSpecs, capBlockNames, breakerName)
% Inserts one gang-operated Three-Phase Breaker in series between
% busPortSpecs{k} and capBlockNames{k}/LConn1 for k = 1:3, defaulting to
% permanently CLOSED with no switching times - the capacitor bank stays in
% service exactly as it did before this breaker existed. Idempotent.

brkPath = [modelName '/' breakerName];
if getSimulinkBlockHandle(brkPath) > 0
    return;
end

% Detach each cap leg from its original bus connection. Using the cap
% block's OWN LConn1 line (rather than searching lines at the bus port) is
% safe even though other loads fan out from the same bus port, since only
% the single line feeding this specific block is touched.
for k = 1:3
    capPath = [modelName '/' capBlockNames{k}];
    ph = get_param(capPath, 'PortHandles');
    lineH = get_param(ph.LConn(1), 'Line');
    if lineH <= 0
        error('extend_fault_injection:CapLineMissing', ...
            '%s has no incoming connection on LConn1.', capBlockNames{k});
    end
    delete_line(lineH);
end

add_block(tieBreakerBlk, brkPath, 'Position', nextSlot(modelName));
% Three-Phase Breaker's switching-time dialog parameter is 'SwitchTimes'
% (NOT 'SwitchingTimes' - that name belongs to the single-phase Breaker
% block used elsewhere in this file). Confirmed via get_param(...,
% 'DialogParameters') on a live CapBrk_675 instance. External MUST be off,
% same reasoning as the single-phase Breaker: left on, it silently ignores
% SwitchTimes/InitialState and reads state from an unconnected control port.
% SwitchTimes must never be empty ('[]') - the block's mask initialization
% indexes into it unconditionally and throws "Index exceeds array bounds"
% if it's empty, so a bracketed time far past any run's T_STOP ('[1e6]') is
% used as the "never actually switches" default instead.
set_param(brkPath, 'InitialState', 'closed', 'External', 'off', 'SwitchTimes', '[1e6]');

for k = 1:3
    add_line(modelName, busPortSpecs{k}, sprintf('%s/LConn%d', breakerName, k), 'autorouting', 'on');
    add_line(modelName, sprintf('%s/RConn%d', breakerName, k), [capBlockNames{k} '/LConn1'], 'autorouting', 'on');
end
end

%% ======================================================================
function insertCapBreaker1ph(modelName, faultBreakerBlk, busPortSpec, capBlockName, breakerName)
% Single-phase equivalent of insertCapBreaker3ph, for the phase-C-only
% capacitor bank at Bus 611. Defaults permanently CLOSED, no switching.
% Idempotent.

brkPath = [modelName '/' breakerName];
if getSimulinkBlockHandle(brkPath) > 0
    return;
end

capPath = [modelName '/' capBlockName];
ph = get_param(capPath, 'PortHandles');
lineH = get_param(ph.LConn(1), 'Line');
if lineH <= 0
    error('extend_fault_injection:CapLineMissing', ...
        '%s has no incoming connection on LConn1.', capBlockName);
end
delete_line(lineH);

add_block(faultBreakerBlk, brkPath, 'Position', nextSlot(modelName));
set_param(brkPath, 'External', 'off', 'InitialState', '1', 'SwitchingTimes', '[1e6]');

add_line(modelName, busPortSpec, [breakerName '/LConn1'], 'autorouting', 'on');
add_line(modelName, [breakerName '/RConn1'], [capBlockName '/LConn1'], 'autorouting', 'on');
end

%% ======================================================================
function addLoadStepBank(modelName, tieBreakerBlk, rlcLoadBlk, groundBlk, busPortSpecs, breakerName, loadNamePrefix, Pph, Qph)
% Adds a 3-phase Y-connected step-load bank behind a gang Three-Phase
% Breaker at busPortSpecs, for synthesizing benign step-load-change
% transients. Defaults permanently OPEN with no switching times: the bank
% carries no current and has zero effect on the network until
% generate_dataset.m commands a switching event. Idempotent.

brkPath = [modelName '/' breakerName];
if getSimulinkBlockHandle(brkPath) > 0
    return;
end

add_block(tieBreakerBlk, brkPath, 'Position', nextSlot(modelName));
% See insertCapBreaker3ph above: Three-Phase Breaker uses 'SwitchTimes'
% (not 'SwitchingTimes'), External must be off, and SwitchTimes must never
% be empty (mask-init "Index exceeds array bounds") - use a far-future
% bracketed time as the "never switches" default instead.
set_param(brkPath, 'InitialState', 'open', 'External', 'off', 'SwitchTimes', '[1e6]');

for k = 1:3
    loadName = sprintf('%s%s_671', loadNamePrefix, char('A' + k - 1));
    loadPath = [modelName '/' loadName];
    add_block(rlcLoadBlk, loadPath, 'Position', nextSlot(modelName));
    set_param(loadPath, 'NominalVoltage', '2400', 'NominalFrequency', '60', ...
        'LoadType', 'constant PQ', 'ActivePower', num2str(Pph), ...
        'InductivePower', num2str(Qph), 'CapacitivePower', '0');

    gndName = [loadName '_Gnd'];
    add_block(groundBlk, [modelName '/' gndName], 'Position', nextSlot(modelName));

    add_line(modelName, busPortSpecs{k}, sprintf('%s/LConn%d', breakerName, k), 'autorouting', 'on');
    add_line(modelName, sprintf('%s/RConn%d', breakerName, k), [loadName '/LConn1'], 'autorouting', 'on');
    add_line(modelName, [loadName '/RConn1'], [gndName '/LConn1'], 'autorouting', 'on');
end
end

%% ======================================================================
function libRoot = locateSpsLibrary()
% Specialized Power Systems library name varies by release.
for cand = ["sps_lib", "powerlib"]
    try
        load_system(cand);
        libRoot = char(cand);
        return;
    catch
    end
end
error('extend_fault_injection:LibraryNotFound', ...
    'Specialized Power Systems library not found. Verify Simscape Electrical is installed.');
end

%% ======================================================================
function pos = nextSlot(modelName)
% Returns a block position in a clear strip below everything currently in
% modelName, so new blocks never land on top of the existing verified
% layout. A persistent slot counter (scoped to this script's execution)
% fans successive blocks out in a grid within that strip.
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
