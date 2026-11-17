function benchmark_clearing_times(mode, interlock, relaySet)
%BENCHMARK_CLEARING_TIMES  Closed-loop fault-clearing timeline of the RF,
% LightGBM and wide 1D-CNN relays in ieee13_hif_twin_system.slx (journal
% comparison, stage 4).
%
%   benchmark_clearing_times()          full study (parfor - run as a batch
%                                       job with a pool, e.g.
%                                       batch(c, @benchmark_clearing_times, 0, {}, 'Pool', 3))
%   benchmark_clearing_times('smoke')   one 633A run per relay, 3-cycle breaker, serial
%   benchmark_clearing_times(mode, true)  the same with the inter-relay
%                                       interlock on (add_relay_interlock.m);
%                                       outputs get the suffix _interlock
%   benchmark_clearing_times(mode, interlock, 'noiseaug')  the noise-augmented
%                                       relays (hif_relay_model_noiseaug.mat,
%                                       hif_relay_lgbm_noiseaug.mat,
%                                       hif_relay_cnn_wide_noiseaug.mat), 3-cycle
%                                       breaker only; suffix _noiseaug
%
% Study design
%   relays     RF (models/hif_relay_model.mat, deployed), LightGBM
%              (hif_relay_lgbm.mat), wide 1D-CNN (hif_relay_cnn_wide.mat)
%   breaker    mechanical operating time 0, 3 and 5 cycles (add_breaker_delay.m)
%   HIF cases  the 8 HIF cases of verify_twin_isolation.m (typical arc on
%              633A/B/C and 675A/B/C, weak arc on 633B and 675C), each at
%              four inception instants 0.100 + {0, 2.1, 4.2, 6.25} ms - spread
%              over one 8.35 ms relay decision period, so timing is reported as
%              a distribution instead of one point
%   decoys     healthy feeder, 675 capacitor bank opens, 611C capacitor opens,
%              671 step load closes; once per relay (no breaker operates
%              unless a relay false-trips)
%   runs       0.45 s, so a slow detection plus a 5-cycle breaker still clears
%              and confirms isolation inside the run
% Timeline per run: extract_clearing_timeline.m.
%
% Outputs: results/dl/clearing_times.csv (one row per run),
%          results/dl/clearing_times_examples.mat (633A typical, offset 0,
%          3-cycle breaker: full waveforms per relay, for figures)

if nargin < 1 || isempty(mode)
    mode = 'full';
end
if nargin < 2
    interlock = false;
end
if nargin < 3
    relaySet = 'clean';
end
projectRoot = fileparts(fileparts(mfilename('fullpath')));
relays = {'RF', 'hif_relay_model.mat'; 'LightGBM', 'hif_relay_lgbm.mat'; 'CNN wide', 'hif_relay_cnn_wide.mat'};
delays = [0 3 5];
if strcmp(relaySet, 'noiseaug')
    relays = {'RF noise-trained', 'hif_relay_model_noiseaug.mat'; 'LightGBM noise-trained', 'hif_relay_lgbm_noiseaug.mat'; ...
              'CNN wide noise-trained', 'hif_relay_cnn_wide_noiseaug.mat'};
    delays = 3;
end
offsets = [0 2.1 4.2 6.25] * 1e-3;
typical = {'Vp', 1500, 'Vn', 2000, 'Rp', 200, 'Rn', 300};
weak    = {'Vp', 2400, 'Vn', 2500, 'Rp', 2000, 'Rn', 2000};
hif = {'633A typical', [{'Bus', '633', 'Phase', 'A'}, typical]
       '633B typical', [{'Bus', '633', 'Phase', 'B'}, typical]
       '633C typical', [{'Bus', '633', 'Phase', 'C'}, typical]
       '675A typical', [{'Bus', '675', 'Phase', 'A'}, typical]
       '675B typical', [{'Bus', '675', 'Phase', 'B'}, typical]
       '675C typical', [{'Bus', '675', 'Phase', 'C'}, typical]
       '633B weak',    [{'Bus', '633', 'Phase', 'B'}, weak]
       '675C weak',    [{'Bus', '675', 'Phase', 'C'}, weak]};
decoys = {'Healthy', 'none'; 'Cap bank 675 opens', 'cap675'; 'Cap 611C opens', 'cap611'; 'Load step 671', 'loadstep'};
STOP = 0.45;

% run list: relay, case name, scenario, options, delay, offset
jobs = {};
for m = 1:size(relays, 1)
    for d = delays
        for c = 1:size(hif, 1)
            for o = offsets
                jobs(end + 1, :) = {m, hif{c, 1}, 'hif', hif{c, 2}, d, o}; %#ok<AGROW>
            end
        end
    end
    for c = 1:size(decoys, 1)
        jobs(end + 1, :) = {m, decoys{c, 1}, decoys{c, 2}, {}, 0, 0}; %#ok<AGROW>
    end
end
if strcmp(mode, 'smoke')
    jobs = {1, '633A typical', 'hif', hif{1, 2}, 3, 0; 2, '633A typical', 'hif', hif{1, 2}, 3, 0; ...
            3, '633A typical', 'hif', hif{1, 2}, 3, 0; 1, '633C typical', 'hif', hif{3, 2}, 3, 0};
end
nJ = size(jobs, 1);
fprintf('%d closed-loop runs\n', nJ);

rows = cell(nJ, 1);
examples = cell(nJ, 1);
if strcmp(mode, 'smoke')
    for j = 1:nJ
        [rows{j}, examples{j}] = runOne(jobs(j, :), relays, STOP, true, interlock);
        disp(rows{j});
    end
else
    parfor j = 1:nJ
        keep = strcmp(jobs{j, 2}, '633A typical') && jobs{j, 5} == 3 && jobs{j, 6} == 0;
        [rows{j}, examples{j}] = runOne(jobs(j, :), relays, STOP, keep, interlock);
    end
end
T = struct2table(vertcat(rows{:}));
ms = @(a, b) 1e3 * (T.(a) - T.(b));
T.detect_ms = ms('t1', 't0');
T.confirm_ms = ms('t2', 't1');
T.trip_ms = ms('t2', 't0');
T.mechanical_ms = ms('t3', 't2');
T.extinction_ms = ms('t4', 't3');
T.clearing_ms = ms('t4', 't0');
T.interruption_ms = ms('t4all', 't0');
T.isolation_ms = ms('t5', 't0');
T.clearing_cycles = T.clearing_ms / (1e3 / 60);
suffix = '';
if interlock
    suffix = '_interlock';
end
if strcmp(relaySet, 'noiseaug')
    suffix = [suffix '_noiseaug'];
end
if strcmp(mode, 'smoke')
    suffix = [suffix '_smoke'];
end
writetable(T, fullfile(projectRoot, 'results', 'dl', ['clearing_times' suffix '.csv']));
ex = examples(~cellfun(@isempty, examples));
save(fullfile(projectRoot, 'results', 'dl', ['clearing_times_examples' suffix '.mat']), 'ex', '-v7.3');
fprintf('Saved results/dl/clearing_times%s.csv (%d runs)\n', suffix, height(T));
end

%% ======================================================================
function [row, example] = runOne(job, relays, stop, keep, interlock)
[m, name, scenario, opts, delay, offset] = job{:};
r = run_twin_isolation_case(scenario, opts{:}, 'TEvent', 0.10 + offset, 'StopTime', stop, ...
    'ModelFile', relays{m, 2}, 'BreakerDelayCycles', delay, 'Interlock', interlock);
row = extract_clearing_timeline(r);
row.relay = string(relays{m, 1});
row.caseName = string(name);
row.offset_ms = 1e3 * offset;
example = [];
if keep
    example = struct('relay', relays{m, 1}, 'caseName', name, 'delayCycles', delay, 'time', r.time, ...
        'I_arc', r.I_arc, 'I_633', r.I_633_physical, 'dI_633', r.dI_633, 'class_633', r.class_633, ...
        'trip_633', r.trip_633, 'closeCmd_633', r.closeCmd_633, 'timeline', row);
end
end
