%% profile_rf_compute.m
% Journal comparison study, stage 3: compute footprint of the deployed relay
% pipeline in MATLAB, where it runs - db4 5-level feature extraction
% (hif_window_features.m, also LightGBM's input) and the flattened 100-tree
% Random Forest (rf_flatten.m / rf_predict_flat.m, as HIFRelayBlock calls it).
%
% Edge-relay conditions: single computational thread, one decision at a
% time, over every held-out test window. Also counts the tree nodes stored
% and the node comparisons per decision (same walk as rf_predict_flat).
%
% Output: results/dl/compute_matlab.json

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);
prevThreads = maxNumCompThreads(1);
cleanup = onCleanup(@() maxNumCompThreads(prevThreads));

Wtab = readtable(fullfile(projectRoot, 'data', 'dl', 'windows.csv'), 'TextType', 'string');
man = jsondecode(fileread(fullfile(projectRoot, 'data', 'dl', 'manifest.json')));
W = man.window_len;
fid = fopen(fullfile(projectRoot, 'data', 'dl', 'windows_f32.bin'), 'r');
raw = reshape(fread(fid, inf, 'single=>single'), W, 3, []);
fclose(fid);
test = find(Wtab.split == "test");
R = load(fullfile(projectRoot, 'models', 'hif_relay_model.mat'), 'relayModel', 'scaler');
Fl = rf_flatten(R.relayModel);
nT = numel(test);

% warm-up, then time feature extraction and the forest separately
for r = 1:50
    z = (hif_window_features(raw(:, :, test(r))) - R.scaler.mu) ./ R.scaler.sigma;
    rf_predict_flat(Fl, z);
end
tFeat = zeros(nT, 1);
tRF = zeros(nT, 1);
visits = zeros(nT, 1);
for r = 1:nT
    seg = raw(:, :, test(r));
    t0 = tic;
    f = hif_window_features(seg);
    tFeat(r) = toc(t0);
    z = (f - R.scaler.mu) ./ R.scaler.sigma;
    t0 = tic;
    rf_predict_flat(Fl, z);
    tRF(r) = toc(t0);
    visits(r) = nodeComparisons(Fl, z);
end

nodes = sum(cellfun(@(c) size(c, 1), Fl.children));
leaves = sum(cellfun(@(c) nnz(c(:, 1) == 0), Fl.children));
flatBytes = 0;
for fld = {'cutVar', 'cutPoint', 'children', 'leafProb'}
    flatBytes = flatBytes + sum(cellfun(@(c) numel(c) * 8, Fl.(fld{1})));
end
compact = R.relayModel;
w = whos('compact');

stats = @(t) struct('median_ms', 1e3 * median(t), 'p99_ms', 1e3 * prctile(t, 99), 'mean_ms', 1e3 * mean(t), 'n', numel(t));
out.test_windows = nT;
out.threads = 1;
out.feature_extraction = stats(tFeat);
out.rf = struct('trees', numel(Fl.children), 'nodes', nodes, 'leaves', leaves, ...
    'internal_nodes', nodes - leaves, 'stored_kb_flat_double', flatBytes / 1024, ...
    'stored_kb_compact_ensemble_in_memory', w.bytes / 1024, ...
    'node_comparisons_per_decision_mean', mean(visits), 'latency_flat', stats(tRF), ...
    'latency_features_plus_rf', stats(tFeat + tRF));
fid = fopen(fullfile(projectRoot, 'results', 'dl', 'compute_matlab.json'), 'w');
fprintf(fid, '%s', jsonencode(out, 'PrettyPrint', true));
fclose(fid);
fprintf(['Feature extraction: median %.3f ms (p99 %.3f) | RF flat: median %.3f ms (p99 %.3f) | ' ...
    '%d trees, %d nodes, %.0f comparisons/decision\n'], out.feature_extraction.median_ms, ...
    out.feature_extraction.p99_ms, out.rf.latency_flat.median_ms, out.rf.latency_flat.p99_ms, ...
    out.rf.trees, nodes, mean(visits));

%% ======================================================================
function n = nodeComparisons(F, z)
n = 0;
for t = 1:numel(F.cutVar)
    node = 1;
    children = F.children{t};
    while children(node, 1) > 0
        n = n + 1;
        if z(F.cutVar{t}(node)) < F.cutPoint{t}(node)
            node = children(node, 1);
        else
            node = children(node, 2);
        end
    end
end
end
