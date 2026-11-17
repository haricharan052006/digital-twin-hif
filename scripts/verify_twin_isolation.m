%% verify_twin_isolation.m
% Closed-loop verification of ieee13_hif_twin_system.slx: runs a scenario
% matrix through run_twin_isolation_case.m and checks that the in-model
% relays trip the FAULTED lateral only, and never trip for healthy
% operation or benign switching.
%
% Scenarios (all events at t = 0.10 s, 0.30 s runs):
%   - healthy feeder                              -> no trip
%   - typical HIF (Vp 1500 V, Vn 2000 V, Rp 200 Ohm, Rn 300 Ohm) on each
%     of 633A/B/C and 675A/B/C                    -> trip that lateral only
%   - weak HIF near the strikeable limit (Vp 2400 V, Vn 2500 V, Rp = Rn =
%     2000 Ohm) on 633B and 675C                  -> trip that lateral only
%   - 675 capacitor bank opens, 611 capacitor opens, 671 step load closes
%                                                 -> no trip
%
% A tripped lateral is also checked for isolation: its physical lateral
% current and its residual over the last two cycles must be ~0.
%
% Writes results/twin_isolation_results.csv.
%
% Requires models/hif_relay_model.mat (train_classifiers.m) and
% models/ieee13_hif_twin_system.slx (build_twin_system.m).

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);

typical = {'Vp', 1500, 'Vn', 2000, 'Rp', 200, 'Rn', 300};
weak    = {'Vp', 2400, 'Vn', 2500, 'Rp', 2000, 'Rn', 2000};
cases = { ...  % name, scenario, options, expected trip
    'Healthy',            'none',     {},                                     'none'
    'HIF 633A typical',   'hif',      [{'Bus', '633', 'Phase', 'A'}, typical], '633'
    'HIF 633B typical',   'hif',      [{'Bus', '633', 'Phase', 'B'}, typical], '633'
    'HIF 633C typical',   'hif',      [{'Bus', '633', 'Phase', 'C'}, typical], '633'
    'HIF 675A typical',   'hif',      [{'Bus', '675', 'Phase', 'A'}, typical], '675'
    'HIF 675B typical',   'hif',      [{'Bus', '675', 'Phase', 'B'}, typical], '675'
    'HIF 675C typical',   'hif',      [{'Bus', '675', 'Phase', 'C'}, typical], '675'
    'HIF 633B weak',      'hif',      [{'Bus', '633', 'Phase', 'B'}, weak],    '633'
    'HIF 675C weak',      'hif',      [{'Bus', '675', 'Phase', 'C'}, weak],    '675'
    'Cap bank 675 opens', 'cap675',   {},                                     'none'
    'Cap 611C opens',     'cap611',   {},                                     'none'
    'Load step 671',      'loadstep', {},                                     'none'};

ISOLATED_A = 0.05;   % lateral current / residual below this = isolated
n = size(cases, 1);
rows = cell(n, 1);
nPass = 0;
fprintf('=== Closed-loop digital-twin HIF isolation (%d scenarios) ===\n', n);

% Report the relay settings actually stored in the model (block values,
% not class defaults).
sysName = 'ieee13_hif_twin_system';
if ~bdIsLoaded(sysName)
    load_system(fullfile(projectRoot, 'models', [sysName '.slx']));
end
for relay = {'HIF_Relay_633', 'HIF_Relay_675'}
    blk = [sysName '/' relay{1}];
    fprintf('%s: trip on %s of the last %s decisions, evaluated every %s samples\n', relay{1}, ...
        get_param(blk, 'ConfirmCount'), get_param(blk, 'ConfirmWindow'), get_param(blk, 'EvalSteps'));
end
fprintf('%-20s | %-8s | %-8s | %-9s | %-9s | %-18s | %s\n', 'Scenario', 'Expected', 'Tripped', ...
    'Trip 633', 'Trip 675', 'Isolated (I, dI)', 'Result');
for i = 1:n
    r = run_twin_isolation_case(cases{i, 2}, cases{i, 3}{:});
    expected = cases{i, 4};
    pass = strcmp(r.tripped, expected);
    isoStr = '-';
    if ~strcmp(expected, 'none') && pass
        Iend  = r.(['I' expected 'L_endRMS']);
        dIend = r.(['dI' expected 'L_endRMS']);
        isolated = Iend < ISOLATED_A && dIend < ISOLATED_A;
        pass = pass && isolated;
        isoStr = sprintf('%s (%.3f, %.3f A)', mat2str(isolated), Iend, dIend);
    end
    nPass = nPass + pass;
    fprintf('%-20s | %-8s | %-8s | %-9s | %-9s | %-18s | %s\n', cases{i, 1}, expected, r.tripped, ...
        delayStr(r.tripTime633, r.tEvent), delayStr(r.tripTime675, r.tEvent), isoStr, passStr(pass));
    rows{i} = {cases{i, 1}, expected, r.tripped, r.tripTime633, r.tripTime675, ...
        1e3 * (min(r.tripTime633, r.tripTime675, 'omitnan') - r.tEvent), ...
        r.I633L_endRMS, r.I675L_endRMS, r.dI633L_endRMS, r.dI675L_endRMS, pass};
end

T = cell2table(vertcat(rows{:}), 'VariableNames', {'Scenario', 'Expected', 'Tripped', ...
    'TripTime633_s', 'TripTime675_s', 'DetectionDelay_ms', 'I633L_end_A', 'I675L_end_A', ...
    'dI633L_end_A', 'dI675L_end_A', 'Pass'});
csvFile = fullfile(projectRoot, 'results', 'twin_isolation_results.csv');
writetable(T, csvFile);
fprintf('\n%d / %d scenarios passed. Results: %s\n', nPass, n, csvFile);

%% ======================================================================
function s = delayStr(tTrip, tEvent)
if isnan(tTrip)
    s = '-';
else
    s = sprintf('+%.0f ms', 1e3 * (tTrip - tEvent));
end
end

function s = passStr(tf)
if tf
    s = 'PASS';
else
    s = 'FAIL';
end
end
