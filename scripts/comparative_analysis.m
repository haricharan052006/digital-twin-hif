function comparative_analysis()
%COMPARATIVE_ANALYSIS  Tables and figures of the extended model comparison
% (journal study): every model on the same 180 held-out test runs, scored by
% relay_window_metrics.m.
%
% Tables, results/dl/comparative/:
%   test_metrics.csv       full metric set per model (mean / sd over seeds)
%   class_f1.csv           per-class precision, recall, F1
%   bootstrap_models.csv   95 % run-level bootstrap interval per model and metric
%   bootstrap_pairs.csv    pairwise differences with 95 % bootstrap interval
%   noise_grid.csv         detection / weak-arc / false trips, model x sigma
%   subgroup_cv.csv        detection by arc strength, phase, lateral (cross-validation)
%   closed_loop_cases.csv  median trip and clearing per fault case and relay
%   feature_groups.csv     importance by wavelet band and statistic; noise shift
%   scorecard.csv          best model per criterion
% Figures, results/report_figures/fig_cmp_*.{pdf,png}.
%
% The bootstrap resamples whole test runs (5000 draws, fixed seed) and averages
% a model's seeds, so it reflects the finite test set, not training randomness.
% Run in a batch worker (headless figure export).

root = fileparts(fileparts(mfilename('fullpath')));
res = fullfile(root, 'results', 'dl');
out = fullfile(res, 'comparative');
figDir = fullfile(root, 'results', 'report_figures');
W = readtable(fullfile(root, 'data', 'dl', 'windows.csv'), 'TextType', 'string');
R = readtable(fullfile(root, 'data', 'dl', 'runs.csv'), 'TextType', 'string');
noise = jsondecode(fileread(fullfile(root, 'data', 'dl', 'noise', 'noise.json')));
sigmas = noise.sigmas(:)';

M = modelList();
nM = numel(M);
classNames = {'Normal', 'Switching', 'HIF A', 'HIF B', 'HIF C'};

%% ---------------------------------------------- per-seed metrics, clean test
fields = {'Accuracy', 'MacroF1', 'HifPrecision', 'HifRecall', 'HifF1', 'FalseHifRate', 'AUC', 'Dependability', ...
    'DependabilityWeak', 'Security', 'FalseTrips', 'FalseTripsAdjacent', 'FalseTripsNormalSwitching', 'FalseTripsPreInception'};
rows = {};
classRows = {};
conf = cell(nM, 1);
for k = 1:nM
    P = loadTest(res, M(k).id);
    vals = zeros(numel(P), numel(fields));
    C = 0;
    prc = zeros(numel(P), 5);
    rcl = zeros(numel(P), 5);
    for s = 1:numel(P)
        m = relay_window_metrics(W(P{s}.row, :), P{s}.pred);
        cm = m.ConfusionMatrix;
        hifTP = sum(cm(3:5, 3:5), 'all');
        hp = hifTP / max(1, sum(cm(:, 3:5), 'all'));
        hr = hifTP / max(1, sum(cm(3:5, :), 'all'));
        truth = W.code(P{s}.row) >= 2;
        [~, ~, ~, auc] = perfcurve(truth, P{s}.p2 + P{s}.p3 + P{s}.p4, true);
        vals(s, :) = [m.Accuracy, m.MacroF1, hp, hr, 2 * hp * hr / max(eps, hp + hr), m.FalseHifRate, auc, m.Dependability, ...
            m.DependabilityWeak, m.Security, m.FalseTrips, m.FalseTripsAdjacent, m.FalseTripsNormalSwitching, m.FalseTripsPreInception];
        C = C + cm ./ max(1, sum(cm, 2));
        prc(s, :) = m.PerClassPrecision;
        rcl(s, :) = m.PerClassRecall;
    end
    conf{k} = 100 * C / numel(P);
    rows(end + 1, :) = [{M(k).id, M(k).label, numel(P)}, num2cell(mean(vals, 1)), num2cell(std(vals, 0, 1))]; %#ok<AGROW>
    f1 = 2 * prc .* rcl ./ max(eps, prc + rcl);
    classRows(end + 1, :) = [{M(k).label}, num2cell(mean(prc, 1)), num2cell(mean(rcl, 1)), num2cell(mean(f1, 1))]; %#ok<AGROW>
end
Tm = cell2table(rows, 'VariableNames', [{'Model', 'Label', 'Seeds'}, fields, strcat(fields, '_std')]);
writetable(Tm, fullfile(out, 'test_metrics.csv'));
tags = {'Normal', 'Switching', 'HIF_A', 'HIF_B', 'HIF_C'};
Tc = cell2table(classRows, 'VariableNames', [{'Label'}, strcat('P_', tags), strcat('R_', tags), strcat('F1_', tags)]);
writetable(Tc, fullfile(out, 'class_f1.csv'));

%% ------------------------------------------------ noise grid + per-run outcomes
nS = numel(sigmas);
gridDep = nan(nM, nS);
gridWeak = nan(nM, nS);
gridFT = nan(nM, nS);
gridAcc = nan(nM, nS);
gridFTtype = nan(nM, nS, 3);
runs = unique(W.run(W.split == "test"));
perRun = struct('det', [], 'elig', [], 'detW', [], 'eligW', [], 'ft', []);
perRun = repmat(perRun, nM, nS);
for k = 1:nM
    for i = 1:nS
        P = loadNoise(res, M(k).id, i);
        v = zeros(numel(P), 7);
        o = zeros(numel(runs), 5);
        for s = 1:numel(P)
            m = relay_window_metrics(W(P{s}.row, :), P{s}.pred);
            v(s, :) = [m.Dependability, m.DependabilityWeak, m.FalseTrips, m.Accuracy, ...
                m.FalseTripsAdjacent, m.FalseTripsNormalSwitching, m.FalseTripsPreInception];
            q = m.Seq;
            [~, ix] = ismember(q.run, runs);
            o(:, 1) = o(:, 1) + accumarray(ix, double(q.detected & q.eligible), [numel(runs) 1]);
            o(:, 3) = o(:, 3) + accumarray(ix, double(q.detected & q.eligible & q.weak), [numel(runs) 1]);
            o(:, 5) = o(:, 5) + accumarray(ix, double(q.falseTrip), [numel(runs) 1]);
            o(:, 2) = accumarray(ix, double(q.eligible), [numel(runs) 1]);
            o(:, 4) = accumarray(ix, double(q.eligible & q.weak), [numel(runs) 1]);
        end
        gridDep(k, i) = mean(v(:, 1));
        gridWeak(k, i) = mean(v(:, 2));
        gridFT(k, i) = mean(v(:, 3));
        gridAcc(k, i) = mean(v(:, 4));
        gridFTtype(k, i, :) = mean(v(:, 5:7), 1);
        perRun(k, i) = struct('det', o(:, 1) / numel(P), 'elig', o(:, 2), 'detW', o(:, 3) / numel(P), ...
            'eligW', o(:, 4), 'ft', o(:, 5) / numel(P));
    end
end
gridRows = {};
for k = 1:nM
    for i = 1:nS
        gridRows(end + 1, :) = {M(k).id, M(k).label, sigmas(i), gridAcc(k, i), gridDep(k, i), gridWeak(k, i), gridFT(k, i), ...
            gridFTtype(k, i, 1), gridFTtype(k, i, 2), gridFTtype(k, i, 3)}; %#ok<AGROW>
    end
end
writetable(cell2table(gridRows, 'VariableNames', {'Model', 'Label', 'Sigma_A', 'Accuracy', 'Dependability', 'DependabilityWeak', ...
    'FalseTrips', 'FalseTripsAdjacent', 'FalseTripsNormalSwitching', 'FalseTripsPreInception'}), fullfile(out, 'noise_grid.csv'));

%% ------------------------------------------------------- run-level bootstrap
rng(4242, 'twister');
B = 5000;
nR = numel(runs);
wts = zeros(B, nR);
for b = 1:B
    wts(b, :) = accumarray(randi(nR, nR, 1), 1, [nR 1])';
end
stat = @(q) struct('dep', 100 * (wts * q.det) ./ (wts * q.elig), 'weak', 100 * (wts * q.detW) ./ (wts * q.eligW), 'ft', wts * q.ft);
bootRows = {};
for k = 1:nM
    for i = find(ismember(sigmas, [0 0.1]))
        s = stat(perRun(k, i));
        bootRows(end + 1, :) = {M(k).id, M(k).label, sigmas(i), 100 * gridDep(k, i), prctile(s.dep, 2.5), prctile(s.dep, 97.5), ...
            100 * gridWeak(k, i), prctile(s.weak, 2.5), prctile(s.weak, 97.5), gridFT(k, i), prctile(s.ft, 2.5), prctile(s.ft, 97.5)}; %#ok<AGROW>
    end
end
Tb = cell2table(bootRows, 'VariableNames', {'Model', 'Label', 'Sigma_A', 'Dep', 'Dep_lo', 'Dep_hi', 'Weak', 'Weak_lo', 'Weak_hi', 'FT', 'FT_lo', 'FT_hi'});
writetable(Tb, fullfile(out, 'bootstrap_models.csv'));

pairs = {0, 'lgbm', 'rf'; 0, 'lgbm', 'cnn_wide_ref'; 0, 'rf', 'cnn_wide_ref'; 0, 'lgbm', 'mlp'; 0, 'rf', 'mlp'; 0, 'rf', 'svm'; 0, 'mlp', 'svm'; ...
    0, 'cnn_wide_ref', 'cnn_ref'; 0, 'cnn_wide_ref_aug', 'cnn_wide_ref'; 0, 'lgbm', 'cnn_wide_ref_aug'; 0, 'lgbm', 'lgbm_aug'; ...
    0.1, 'cnn_wide_ref_aug', 'lgbm_aug'; 0.1, 'cnn_wide_ref_aug', 'rf_aug'; 0.1, 'lgbm_aug', 'rf_aug'; 0.1, 'lgbm_aug', 'lgbm'; 0.1, 'rf_aug', 'rf'; 0.1, 'cnn_wide_ref_aug', 'cnn_wide_ref'; ...
    0.05, 'lgbm_aug', 'cnn_wide_ref_aug'; 0.2, 'cnn_wide_ref_aug', 'lgbm_aug'};
ids = string({M.id});
pairRows = {};
for p = 1:size(pairs, 1)
    i = find(sigmas == pairs{p, 1});
    a = find(ids == pairs{p, 2});
    c = find(ids == pairs{p, 3});
    sa = stat(perRun(a, i));
    sc = stat(perRun(c, i));
    dD = sa.dep - sc.dep;
    dW = sa.weak - sc.weak;
    dF = sa.ft - sc.ft;
    pairRows(end + 1, :) = {sigmas(i), M(a).label, M(c).label, 100 * (gridDep(a, i) - gridDep(c, i)), prctile(dD, 2.5), prctile(dD, 97.5), ...
        100 * (gridWeak(a, i) - gridWeak(c, i)), prctile(dW, 2.5), prctile(dW, 97.5), gridFT(a, i) - gridFT(c, i), prctile(dF, 2.5), prctile(dF, 97.5)}; %#ok<AGROW>
end
Tp = cell2table(pairRows, 'VariableNames', {'Sigma_A', 'ModelA', 'ModelB', 'dDep', 'dDep_lo', 'dDep_hi', 'dWeak', 'dWeak_lo', 'dWeak_hi', 'dFT', 'dFT_lo', 'dFT_hi'});
writetable(Tp, fullfile(out, 'bootstrap_pairs.csv'));

%% --------------------------------------------------- subgroups (cross-validation)
cvModels = {'rf', 'Random Forest'; 'lgbm', 'LightGBM'; 'cnn_wide_ref', 'CNN wide'; 'cnn_ref', 'CNN base'};
Rr = R;
meanR = (Rr.Rp + Rr.Rn) / 2;
meanV = (Rr.Vp + Rr.Vn) / 2;
Pcv = readtable(fullfile(res, ['pred_' cvModels{1, 1} '_cv.csv']));
m0 = relay_window_metrics(W(Pcv.row, :), Pcv.pred);
q0 = m0.Seq;
el = q0.eligible;
rEdges = prctile(meanR(q0.run(el)), [100/3 200/3]);
vEdges = prctile(meanV(q0.run(el)), [100/3 200/3]);
bin = @(v, e) 1 + (v > e(1)) + (v > e(2));
groupNames = {sprintf('R < %.0f \\Omega', rEdges(1)), sprintf('R %.0f-%.0f \\Omega', rEdges), sprintf('R > %.0f \\Omega', rEdges(2)), ...
    sprintf('V < %.0f V', vEdges(1)), sprintf('V %.0f-%.0f V', vEdges), sprintf('V > %.0f V', vEdges(2)), ...
    'Phase A', 'Phase B', 'Phase C', 'Lateral 633', 'Lateral 675', 'Main set', 'Weak set'};
Dsub = nan(size(cvModels, 1), numel(groupNames));
Nsub = zeros(1, numel(groupNames));
for k = 1:size(cvModels, 1)
    Pc = readtable(fullfile(res, ['pred_' cvModels{k, 1} '_cv.csv']));
    q = relay_window_metrics(W(Pc.row, :), Pc.pred).Seq;
    e = find(q.eligible);
    rn = q.run(e);
    det = q.detected(e);
    ph = Rr.phase(rn);
    lat = q.lat675(e);
    grp = {bin(meanR(rn), rEdges) == 1, bin(meanR(rn), rEdges) == 2, bin(meanR(rn), rEdges) == 3, ...
        bin(meanV(rn), vEdges) == 1, bin(meanV(rn), vEdges) == 2, bin(meanV(rn), vEdges) == 3, ...
        ph == "A", ph == "B", ph == "C", ~lat, lat, Rr.source(rn) == "main", Rr.source(rn) == "boundary"};
    for g = 1:numel(grp)
        Dsub(k, g) = 100 * mean(det(grp{g}));
        Nsub(g) = nnz(grp{g});
    end
end
Ts = array2table(Dsub, 'VariableNames', matlab.lang.makeValidName(regexprep(groupNames, '\\Omega', 'Ohm')));
Ts = addvars(Ts, string(cvModels(:, 2)), 'Before', 1, 'NewVariableNames', 'Model');
Ts = [Ts; [{"Sequences"}, num2cell(Nsub)]];
writetable(Ts, fullfile(out, 'subgroup_cv.csv'));

%% ----------------------------------------------------------- closed-loop cases
CLc = readRuns(fullfile(res, 'clearing_times_interlock.csv'));
CLc = CLc(CLc.delayCycles == 3 & CLc.scenario == "hif", :);
CLn = readRuns(fullfile(res, 'clearing_times_interlock_noiseaug.csv'));
CLn = CLn(CLn.scenario == "hif", :);
CL = [CLc; CLn];
relays = ["RF", "LightGBM", "CNN wide", "RF noise-trained", "LightGBM noise-trained", "CNN wide noise-trained"];
cases = ["633A typical", "633B typical", "633C typical", "675A typical", "675B typical", "675C typical", "633B weak", "675C weak"];
gridTrip = nan(numel(relays), numel(cases));
gridClear = nan(numel(relays), numel(cases));
gridMiss = zeros(numel(relays), numel(cases));
for a = 1:numel(relays)
    for c = 1:numel(cases)
        s = CL(CL.relay == relays(a) & CL.caseName == cases(c), :);
        gridMiss(a, c) = nnz(s.missed);
        ok = ~s.missed;
        if any(ok)
            gridTrip(a, c) = median(s.trip_ms(ok));
            gridClear(a, c) = median(s.clearing_ms(ok));
        end
    end
end
Tcl = table(repelem(relays', numel(cases)), repmat(cases', numel(relays), 1), reshape(gridTrip', [], 1), reshape(gridClear', [], 1), ...
    reshape(gridMiss', [], 1), 'VariableNames', {'Relay', 'Case', 'TripMedian_ms', 'ClearMedian_ms', 'Missed_of_4'});
writetable(Tcl, fullfile(out, 'closed_loop_cases.csv'));

%% ------------------------------------------- feature groups: importance, noise shift
Fx = load(fullfile(root, 'data', 'features.mat'), 'featureNames');
names = string(Fx.featureNames);
ex = jsondecode(fileread(fullfile(out, 'extras.json')));
R1 = load(fullfile(root, 'models', 'hif_relay_model.mat'), 'relayModel');
R2 = load(fullfile(root, 'models', 'hif_relay_model_noiseaug.mat'), 'relayModel');
imp = [normalize1(predictorImportance(R1.relayModel)'), normalize1(predictorImportance(R2.relayModel)'), ...
    ex.lgbm.lgbm.gain_share(:), ex.lgbm.lgbm_aug.gain_share(:)];
bands = ["A5", "D5", "D4", "D3", "D2", "D1", "time", "cross"];
bandOf = strings(size(names));
for b = bands(1:6)
    bandOf(contains(names, "_" + b + "_")) = b;
end
bandOf(contains(names, "_time_")) = "time";
bandOf(bandOf == "") = "cross";
statsList = ["Energy", "Entropy", "Std", "MaxAbs", "time moments", "cross-phase"];
statOf = strings(size(names));
for s = statsList(1:4)
    statOf(endsWith(names, "_" + s) & ~contains(names, "_time_")) = s;
end
statOf(contains(names, "_time_")) = "time moments";
statOf(statOf == "") = "cross-phase";
impBand = zeros(numel(bands), 4);
for b = 1:numel(bands)
    impBand(b, :) = 100 * sum(imp(bandOf == bands(b), :), 1);
end
impStat = zeros(numel(statsList), 4);
for s = 1:numel(statsList)
    impStat(s, :) = 100 * sum(imp(statOf == statsList(s), :), 1);
end
% How far noise moves each feature group on Normal test windows: median
% absolute shift in units of the feature's interquartile range on clean windows.
nf = noise.n_features;
base = readFeat(root, 1, nf);
isNormal = W.code(noise.rows) == 0;
iqrClean = max(iqr(base(isNormal, :), 1), eps);
sigShow = [0.005 0.05 0.1];
shift = zeros(numel(bands), numel(sigShow));
for j = 1:numel(sigShow)
    Xn = readFeat(root, find(sigmas == sigShow(j)), nf);
    dz = median(abs(Xn(isNormal, :) - base(isNormal, :)), 1) ./ iqrClean;
    for b = 1:numel(bands)
        shift(b, j) = median(dz(bandOf == bands(b)));
    end
end
Tf = table(bands', impBand(:, 1), impBand(:, 2), impBand(:, 3), impBand(:, 4), shift(:, 1), shift(:, 2), shift(:, 3), ...
    'VariableNames', {'Band', 'RF_clean', 'RF_noise', 'LGBM_clean', 'LGBM_noise', 'Shift_5mA', 'Shift_50mA', 'Shift_100mA'});
writetable(Tf, fullfile(out, 'feature_groups.csv'));
writetable(table(statsList', impStat(:, 1), impStat(:, 2), impStat(:, 3), impStat(:, 4), 'VariableNames', ...
    {'Statistic', 'RF_clean', 'RF_noise', 'LGBM_clean', 'LGBM_noise'}), fullfile(out, 'feature_stats.csv'));

%% ------------------------------------------------------------------- scorecard
cd0 = 100 * gridDep;
scoreDefs = {
    'Fault detection, no noise', cd0(:, sigmas == 0), 'max', '%.1f %%'
    'Weak-arc detection, no noise', 100 * gridWeak(:, sigmas == 0), 'max', '%.1f %%'
    'Fewest false trips, no noise', gridFT(:, sigmas == 0), 'min', '%.1f'
    'Macro F1, no noise', Tm.MacroF1, 'max', '%.3f'
    'AUC, HIF vs rest', Tm.AUC, 'max', '%.4f'
    'Fault detection, 20 mA', cd0(:, sigmas == 0.02), 'max', '%.1f %%'
    'Fewest false trips, 20 mA', gridFT(:, sigmas == 0.02), 'min', '%.1f'
    'Fault detection, 50 mA', cd0(:, sigmas == 0.05), 'max', '%.1f %%'
    'Weak-arc detection, 50 mA', 100 * gridWeak(:, sigmas == 0.05), 'max', '%.1f %%'
    'Fault detection, 0.1 A', cd0(:, sigmas == 0.1), 'max', '%.1f %%'
    'Weak-arc detection, 0.1 A', 100 * gridWeak(:, sigmas == 0.1), 'max', '%.1f %%'
    'Fewest false trips, 0.1 A', gridFT(:, sigmas == 0.1), 'min', '%.1f'
    'Fault detection, 0.2 A', cd0(:, sigmas == 0.2), 'max', '%.1f %%'
    'Weak-arc detection, 0.2 A', 100 * gridWeak(:, sigmas == 0.2), 'max', '%.1f %%'};
sc = cell(size(scoreDefs, 1), 3);
for s = 1:size(scoreDefs, 1)
    v = scoreDefs{s, 2};
    if strcmp(scoreDefs{s, 3}, 'max')
        best = max(v);
    else
        % A relay that detects under 50 % of faults at this noise level does
        % not win on false trips (the SVM trips on nothing above 10 mA).
        lvl = regexp(scoreDefs{s, 1}, ', (.+)$', 'tokens', 'once');
        iS = find(sigmas == sscanf(strrep(strrep(lvl{1}, 'no noise', '0'), ' mA', 'e-3'), '%f'));
        v(gridDep(:, iS) < 0.5) = NaN;
        best = min(v);
    end
    w = abs(v - best) < 1e-9;
    sc(s, :) = {scoreDefs{s, 1}, strjoin({M(w).label}, ', '), sprintf(scoreDefs{s, 4}, best)};
end
writetable(cell2table(sc, 'VariableNames', {'Criterion', 'Best', 'Value'}), fullfile(out, 'scorecard.csv'));

%% ===================================================================== figures
figOverall(M, Tm, Tb, sigmas, figDir);
figConfusion(M, conf, classNames, figDir);
figRoc(M, W, res, root, figDir);
figNoiseGrid(M, sigmas, gridDep, gridWeak, gridFT, figDir);
figSubgroups(cvModels, groupNames, Dsub, Nsub, figDir);
figFalseTrips(M, sigmas, gridFTtype, figDir);
figClosedLoop(CL, relays, cases, gridTrip, gridMiss, figDir);
figImportance(bands, statsList, impBand, impStat, shift, sigShow, figDir);
figTraining(ex, res, figDir);
figPipelines(figDir);
figCompute(out, figDir);
fprintf('Saved results/dl/comparative/* and results/report_figures/fig_cmp_*\n');
end

%% ======================================================================
function M = modelList()
blue = [0.165 0.471 0.839];
orange = [0.922 0.408 0.204];
green = [0.106 0.686 0.478];
purple = [0.384 0.314 0.839];
pink = [0.910 0.482 0.643];
grey = [0.537 0.529 0.506];
d = {'svm', 'SVM', purple, 's1'; 'mlp', 'MLP', pink, 's1'; 'rf', 'RF', blue, 's1'; 'lgbm', 'LightGBM', orange, 's1'; ...
    'cnn_ref', 'CNN base', grey, 's3'; 'cnn_wide_ref', 'CNN wide', green, 's3'; ...
    'rf_aug', 'RF (noise)', blue, 'n1'; 'lgbm_aug', 'LightGBM (noise)', orange, 'n3'; 'cnn_wide_ref_aug', 'CNN wide (noise)', green, 'n3'};
M = struct('id', d(:, 1), 'label', d(:, 2), 'color', d(:, 3), 'tag', d(:, 4));
end

function P = loadTest(res, id)
f = dir(fullfile(res, sprintf('pred_%s_test*.csv', id)));
P = cell(numel(f), 1);
for k = 1:numel(f)
    P{k} = readtable(fullfile(f(k).folder, f(k).name));
end
end

function P = loadNoise(res, id, i)
f = dir(fullfile(res, 'noise', sprintf('pred_%s_sigma%d.csv', id, i)));
if isempty(f)
    f = dir(fullfile(res, 'noise', sprintf('pred_%s_seed*_sigma%d.csv', id, i)));
end
P = cell(numel(f), 1);
for k = 1:numel(f)
    P{k} = readtable(fullfile(f(k).folder, f(k).name));
end
end

function T = readRuns(f)
opts = detectImportOptions(f);
opts = setvartype(opts, intersect(opts.VariableNames, {'scenario', 'bus', 'phase', 'tripped', 'relay', 'caseName', 'missed', ...
    'sympathetic', 'rawSympathetic', 'preInception', 'interlock'}), 'string');
T = readtable(f, opts);
for v = intersect(T.Properties.VariableNames, {'missed', 'sympathetic', 'rawSympathetic', 'preInception'})
    T.(v{1}) = T.(v{1}) == "true" | T.(v{1}) == "1";
end
end

function X = readFeat(root, i, nf)
fid = fopen(fullfile(root, 'data', 'dl', 'noise', sprintf('features_sigma%d.bin', i)), 'r');
X = reshape(fread(fid, inf, 'double'), nf, [])';
fclose(fid);
end

function v = normalize1(v)
v = v(:) / sum(v);
end

function fig = newFig(w, h)
fig = figure('Visible', 'off', 'Color', 'w', 'Units', 'inches', 'Position', [1 1 w h]);
try
    theme(fig, 'light');
catch
end
end

function styleAx(ax)
set(ax, 'FontName', 'Helvetica', 'FontSize', 8, 'Box', 'off', 'TickDir', 'out');
end

function saveFig(fig, figDir, name)
exportgraphics(fig, fullfile(figDir, [name '.png']), 'Resolution', 300);
exportgraphics(fig, fullfile(figDir, [name '.pdf']), 'ContentType', 'vector');
close(fig);
end

function c = barColor(m)
c = m.color;
if m.tag(1) == 's' && ~isequal(m.id, 'cnn_ref')
    c = 0.45 * c + 0.55;       % clean-trained: lighter tint of the family colour
end
end

%% ------------------------------------------------------------------ overall
function figOverall(M, Tm, Tb, sigmas, figDir) %#ok<INUSD>
fig = newFig(7.16, 3.4);
tl = tiledlayout(fig, 1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
n = numel(M);
labels = {M.label};
B0 = Tb(Tb.Sigma_A == 0, :);
panels = {100 * Tm.MacroF1, 100 * Tm.MacroF1_std, 100 * Tm.MacroF1_std, '(a) Macro F1 (window level, x100)'; ...
    B0.Dep, B0.Dep - B0.Dep_lo, B0.Dep_hi - B0.Dep, '(b) Fault detection (%)'; ...
    B0.Weak, B0.Weak - B0.Weak_lo, B0.Weak_hi - B0.Weak, '(c) Weak-arc detection (%)'};
for p = 1:3
    ax = nexttile(tl);
    hold(ax, 'on');
    v = panels{p, 1};
    for k = 1:n
        barh(ax, k, v(k), 0.7, 'FaceColor', barColor(M(k)), 'EdgeColor', 'none');
    end
    errorbar(ax, v, (1:n)', panels{p, 2}, panels{p, 3}, 'horizontal', 'k.', 'MarkerSize', 1, 'CapSize', 2.5, 'LineWidth', 0.7);
    for k = 1:n
        text(ax, 2, k, sprintf('%.1f', v(k)), 'FontSize', 7, 'Color', 'k', 'VerticalAlignment', 'middle');
    end
    set(ax, 'YTick', 1:n, 'YTickLabel', labels, 'YDir', 'reverse', 'XLim', [0 100], 'YLim', [0.4 n + 0.6]);
    if p > 1
        set(ax, 'YTickLabel', {});
    end
    styleAx(ax);
    grid(ax, 'on');
    ax.YGrid = 'off';
    ax.GridAlpha = 0.15;
    title(ax, panels{p, 4}, 'FontWeight', 'normal', 'FontSize', 8.5);
end
saveFig(fig, figDir, 'fig_cmp_overall');
end

%% ---------------------------------------------------------------- confusion
function figConfusion(M, conf, classNames, figDir)
show = ["rf", "lgbm", "cnn_wide_ref", "rf_aug", "lgbm_aug", "cnn_wide_ref_aug"];
fig = newFig(7.16, 4.7);
tl = tiledlayout(fig, 2, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
ids = string({M.id});
cmap = interp1([0 1], [1 1 1; 0.106 0.325 0.620], linspace(0, 1, 128));
for s = 1:numel(show)
    k = find(ids == show(s));
    ax = nexttile(tl);
    imagesc(ax, conf{k}, [0 100]);
    colormap(ax, cmap);
    for r = 1:5
        for c = 1:5
            v = conf{k}(r, c);
            if v >= 0.05
                col = 'k';
                if v > 60
                    col = 'w';
                end
                text(ax, c, r, sprintf('%.1f', v), 'HorizontalAlignment', 'center', 'FontSize', 6.5, 'Color', col);
            end
        end
    end
    set(ax, 'XTick', 1:5, 'XTickLabel', classNames, 'YTick', 1:5, 'YTickLabel', classNames, 'XTickLabelRotation', 35);
    styleAx(ax);
    set(ax, 'FontSize', 7, 'Box', 'on');
    title(ax, M(k).label, 'FontWeight', 'normal', 'FontSize', 9);
    if s > 3
        xlabel(ax, 'Predicted class');
    end
    if s == 1 || s == 4
        ylabel(ax, 'True class');
    end
end
saveFig(fig, figDir, 'fig_cmp_confusion');
end

%% ---------------------------------------------------------------------- ROC
function figRoc(M, W, res, root, figDir)
fig = newFig(7.16, 3.8);
tl = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
lg = jsondecode(fileread(fullfile(root, 'models', 'dl', 'relay_export_lgbm.json')));
lga = jsondecode(fileread(fullfile(root, 'models', 'dl', 'relay_export_lgbm_aug.json')));
cn = jsondecode(fileread(fullfile(root, 'models', 'dl', 'relay_export_cnn_wide_ref.json')));
cna = jsondecode(fileread(fullfile(root, 'models', 'dl', 'relay_export_cnn_wide_ref_aug.json')));
seeds = containers.Map({'lgbm', 'lgbm_aug', 'cnn_wide_ref', 'cnn_wide_ref_aug'}, {lg.seed, lga.seed, cn.seed, cna.seed});
show = {'rf', 'lgbm', 'cnn_wide_ref', 'rf_aug', 'lgbm_aug', 'cnn_wide_ref_aug', 'mlp', 'svm'};
ids = string({M.id});
sigIdx = [1, 6];    % no noise, 0.1 A
ttl = {'(a) No noise', '(b) Noise \sigma = 0.1 A'};
for p = 1:2
    ax = nexttile(tl);
    hold(ax, 'on');
    for s = 1:numel(show)
        id = show{s};
        k = find(ids == id);
        if isKey(seeds, id)
            P = readtable(fullfile(res, 'noise', sprintf('pred_%s_seed%d_sigma%d.csv', id, seeds(id), sigIdx(p))));
        else
            P = readtable(fullfile(res, 'noise', sprintf('pred_%s_sigma%d.csv', id, sigIdx(p))));
        end
        [fpr, tpr, ~, auc] = perfcurve(W.code(P.row) >= 2, P.p2 + P.p3 + P.p4, true);
        ls = '--';
        if M(k).tag(1) == 'n'
            ls = '-';
        end
        plot(ax, max(fpr, 1e-4), 100 * tpr, 'Color', M(k).color, 'LineStyle', ls, 'LineWidth', 1.2, ...
            'DisplayName', sprintf('%s (%.3f)', M(k).label, auc));
    end
    set(ax, 'XScale', 'log', 'XLim', [3e-4 1], 'YLim', [0 100]);
    styleAx(ax);
    grid(ax, 'on');
    ax.GridAlpha = 0.15;
    xlabel(ax, 'False-positive rate, non-HIF windows (log scale)');
    ylabel(ax, 'HIF windows detected (%)');
    title(ax, ttl{p}, 'FontWeight', 'normal', 'FontSize', 9);
    legend(ax, 'Location', 'southoutside', 'NumColumns', 2, 'FontSize', 6.5, 'Box', 'off');
end
saveFig(fig, figDir, 'fig_cmp_roc');
end

%% --------------------------------------------------------------- noise grid
function figNoiseGrid(M, sigmas, gridDep, gridWeak, gridFT, figDir)
fig = newFig(7.16, 3.3);
tl = tiledlayout(fig, 1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
keep = ~strcmp({M.id}, 'cnn_ref');
labels = {M(keep).label};
xl = [{'0'}, arrayfun(@(s) sprintf('%g', s), sigmas(2:end), 'UniformOutput', false)];
data = {100 * gridDep(keep, :), '(a) Fault detection (%)', [0 100], '%.0f'; 100 * gridWeak(keep, :), '(b) Weak-arc detection (%)', [0 100], '%.0f'; ...
    gridFT(keep, :), '(c) False trips (of 360)', [0 60], '%.0f'};
good = interp1([0 1], [1 1 1; 0.106 0.325 0.620], linspace(0, 1, 128));   % more detection = darker blue
bad = interp1([0 1], [1 1 1; 0.75 0.25 0.10], linspace(0, 1, 128));        % more false trips = darker red
noDetect = gridDep(keep, :) == 0;
for p = 1:3
    ax = nexttile(tl);
    im = imagesc(ax, data{p, 1}, data{p, 3});
    if p == 3
        colormap(ax, bad);
        im.AlphaData = double(~noDetect);    % a relay that detects nothing is grey, not "good"
        set(ax, 'Color', [0.82 0.82 0.82]);
    else
        colormap(ax, good);
    end
    [nr, nc] = size(data{p, 1});
    for r = 1:nr
        for c = 1:nc
            v = data{p, 1}(r, c);
            tc = 'k';
            if v > 0.62 * data{p, 3}(2)
                tc = 'w';
            end
            text(ax, c, r, sprintf(data{p, 4}, v), 'HorizontalAlignment', 'center', 'FontSize', 6.5, 'Color', tc);
        end
    end
    set(ax, 'XTick', 1:nc, 'XTickLabel', xl, 'YTick', 1:nr, 'YTickLabel', labels, 'XTickLabelRotation', 45);
    if p > 1
        set(ax, 'YTickLabel', {});
    end
    styleAx(ax);
    set(ax, 'FontSize', 7);
    xlabel(ax, 'Noise \sigma per phase (A)');
    title(ax, data{p, 2}, 'FontWeight', 'normal', 'FontSize', 8.5);
end
saveFig(fig, figDir, 'fig_cmp_noise_grid');
end

%% ---------------------------------------------------------------- subgroups
function figSubgroups(cvModels, groupNames, Dsub, Nsub, figDir)
colors = [0.165 0.471 0.839; 0.922 0.408 0.204; 0.106 0.686 0.478; 0.537 0.529 0.506];
fig = newFig(7.16, 2.9);
tl = tiledlayout(fig, 1, 4, 'TileSpacing', 'compact', 'Padding', 'compact');
sets = {1:3, '(a) Arc resistance', 'mean R_p, R_n (Ohm)'; 4:6, '(b) Breakdown voltage', 'mean V_p, V_n (V)'; 7:9, '(c) Faulted phase', ''; 10:13, '(d) Lateral, dataset', ''};
shortLabels = regexprep(groupNames, {'^R ', '^V ', ' \\Omega$', ' V$', '^Phase ', '^Lateral ', ' set$'}, '');
h = gobjects(0);
for p = 1:4
    ax = nexttile(tl);
    idx = sets{p, 1};
    b = bar(ax, Dsub(:, idx)', 0.85, 'EdgeColor', 'none');
    for k = 1:numel(b)
        b(k).FaceColor = colors(k, :);
        b(k).DisplayName = cvModels{k, 2};
    end
    if p == 1
        h = b;
    end
    lab = shortLabels(idx);
    for q = 1:numel(idx)
        lab{q} = sprintf('%s\\newlinen=%d', lab{q}, Nsub(idx(q)));
    end
    set(ax, 'XTickLabel', lab, 'YLim', [0 100], 'XTickLabelRotation', 0);
    styleAx(ax);
    set(ax, 'FontSize', 7);
    if ~isempty(sets{p, 3})
        xlabel(ax, sets{p, 3});
    end
    grid(ax, 'on');
    ax.XGrid = 'off';
    ax.GridAlpha = 0.15;
    if p == 1
        ylabel(ax, 'Fault detection (%)');
    end
    title(ax, sets{p, 2}, 'FontWeight', 'normal', 'FontSize', 8.5);
end
lg = legend(h, 'Orientation', 'horizontal', 'FontSize', 7.5, 'Box', 'off');
lg.Layout.Tile = 'north';
saveFig(fig, figDir, 'fig_cmp_subgroups');
end

%% -------------------------------------------------------------- false trips
function figFalseTrips(M, sigmas, T3, figDir)
fig = newFig(7.16, 2.8);
tl = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
n = numel(M);
sel = {sigmas == 0, '(a) No noise'; sigmas == 0.1, '(b) Noise \sigma = 0.1 A'};
col = [0.30 0.45 0.69; 0.87 0.52 0.32; 0.55 0.55 0.55];
for p = 1:2
    ax = nexttile(tl);
    v = squeeze(T3(:, sel{p, 1}, :));
    b = barh(ax, v, 'stacked', 'BarWidth', 0.7, 'EdgeColor', 'none');
    names = {'healthy neighbouring lateral', 'normal / switching run', 'before the fault started'};
    for k = 1:3
        b(k).FaceColor = col(k, :);
        b(k).DisplayName = names{k};
    end
    tot = sum(v, 2);
    for k = 1:n
        lbl = sprintf('%.1f', tot(k));
        if strcmp(M(k).id, 'svm') && p == 2
            lbl = '0 (detects no faults at this noise)';
        end
        text(ax, tot(k) + 0.6, k, lbl, 'FontSize', 7, 'VerticalAlignment', 'middle');
    end
    set(ax, 'YTick', 1:n, 'YTickLabel', {M.label}, 'YDir', 'reverse');
    xlim(ax, [0 1.15 * max(tot) + 1]);
    styleAx(ax);
    set(ax, 'FontSize', 7.5);
    grid(ax, 'on');
    ax.YGrid = 'off';
    ax.GridAlpha = 0.15;
    xlabel(ax, 'False trips, of 360 sequences');
    title(ax, sel{p, 2}, 'FontWeight', 'normal', 'FontSize', 9);
    if p == 2
        legend(ax, 'Location', 'southeast', 'FontSize', 7, 'Box', 'off');
    end
end
saveFig(fig, figDir, 'fig_cmp_false_trips');
end

%% -------------------------------------------------------------- closed loop
function figClosedLoop(CL, relays, cases, gridTrip, gridMiss, figDir)
col = [0.165 0.471 0.839; 0.922 0.408 0.204; 0.106 0.686 0.478];
mk = {'o', 's', '^'};
short = ["RF", "LightGBM", "CNN wide", "RF", "LightGBM", "CNN wide"];
fig = newFig(7.16, 3.3);
tl = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
ax = nexttile(tl);
hold(ax, 'on');
for a = 1:numel(relays)
    s = CL(CL.relay == relays(a) & ~CL.missed & ~isnan(CL.t4), :);
    c = col(mod(a - 1, 3) + 1, :);
    jit = (mod((1:height(s))', 7) - 3) * 0.06;
    scatter(ax, a + jit, s.clearing_ms, 14, c, mk{mod(a - 1, 3) + 1}, 'filled', 'MarkerFaceAlpha', 0.55);
    plot(ax, a + [-0.32 0.32], median(s.clearing_ms) * [1 1], 'k-', 'LineWidth', 1.4);
    m = nnz(CL.relay == relays(a) & CL.missed);
    if m > 0
        text(ax, a, 58, sprintf('%d missed', m), 'HorizontalAlignment', 'center', 'FontSize', 6.5, 'Color', [0.3 0.3 0.3]);
    end
end
xline(ax, 3.5, ':', 'Color', [0.5 0.5 0.5]);
yl = [54 140];
ylim(ax, yl);
text(ax, 2, yl(2) - 3, 'clean-trained', 'HorizontalAlignment', 'center', 'FontSize', 8);
text(ax, 5, yl(2) - 3, 'noise-trained', 'HorizontalAlignment', 'center', 'FontSize', 8);
set(ax, 'XTick', 1:6, 'XTickLabel', short, 'XTickLabelRotation', 30, 'XLim', [0.4 6.6]);
styleAx(ax);
grid(ax, 'on');
ax.XGrid = 'off';
ax.GridAlpha = 0.15;
ylabel(ax, 'Fault-clearing time (ms)');
title(ax, '(a) 3-cycle breaker, interlock on (bar = median)', 'FontWeight', 'normal', 'FontSize', 8.5);

ax = nexttile(tl);
imagesc(ax, gridTrip, [10 60]);
colormap(ax, flipud(interp1([0 1], [0.106 0.325 0.620; 1 1 1], linspace(0, 1, 128))));
set(ax, 'Color', [0.92 0.92 0.92]);
for a = 1:numel(relays)
    for c = 1:numel(cases)
        if isnan(gridTrip(a, c))
            txt = 'missed';
        elseif gridMiss(a, c) > 0
            txt = sprintf('%.0f*', gridTrip(a, c));
        else
            txt = sprintf('%.0f', gridTrip(a, c));
        end
        tc = 'k';
        if gridTrip(a, c) > 42
            tc = 'w';
        end
        text(ax, c, a, txt, 'HorizontalAlignment', 'center', 'FontSize', 6.5, 'Color', tc);
    end
end
set(ax, 'XTick', 1:numel(cases), 'XTickLabel', cases, 'XTickLabelRotation', 40, 'YTick', 1:numel(relays), ...
    'YTickLabel', {'RF', 'LightGBM', 'CNN wide', 'RF (noise)', 'LightGBM (noise)', 'CNN wide (noise)'});
styleAx(ax);
set(ax, 'FontSize', 7);
title(ax, '(b) Median trip time, ms (* = some runs missed)', 'FontWeight', 'normal', 'FontSize', 8.5);
saveFig(fig, figDir, 'fig_cmp_closed_loop');
end

%% --------------------------------------------------------------- importance
function figImportance(bands, statsList, impBand, impStat, shift, sigShow, figDir)
col = [0.60 0.75 0.93; 0.165 0.471 0.839; 0.96 0.72 0.60; 0.922 0.408 0.204];
names = {'RF, clean', 'RF, noise-trained', 'LightGBM, clean', 'LightGBM, noise-trained'};
fig = newFig(7.16, 2.9);
tl = tiledlayout(fig, 1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
ax = nexttile(tl);
b = bar(ax, impBand, 0.85, 'EdgeColor', 'none');
for k = 1:4
    b(k).FaceColor = col(k, :);
    b(k).DisplayName = names{k};
end
set(ax, 'XTickLabel', bands);
styleAx(ax);
grid(ax, 'on');
ax.XGrid = 'off';
ax.GridAlpha = 0.15;
ylabel(ax, 'Share of importance (%)');
xlabel(ax, 'Sub-band (A5 low ... D1 high frequency)');
title(ax, '(a) By wavelet band', 'FontWeight', 'normal', 'FontSize', 8.5);
lg = legend(ax, 'Orientation', 'horizontal', 'FontSize', 7.5, 'Box', 'off');
lg.Layout.Tile = 'north';

ax = nexttile(tl);
b = bar(ax, impStat, 0.85, 'EdgeColor', 'none');
for k = 1:4
    b(k).FaceColor = col(k, :);
end
set(ax, 'XTickLabel', statsList, 'XTickLabelRotation', 35);
styleAx(ax);
grid(ax, 'on');
ax.XGrid = 'off';
ax.GridAlpha = 0.15;
title(ax, '(b) By statistic', 'FontWeight', 'normal', 'FontSize', 8.5);

ax = nexttile(tl);
b = bar(ax, max(shift, 1e-3), 0.85, 'EdgeColor', 'none');
shades = [0.75 0.75 0.75; 0.45 0.45 0.45; 0.1 0.1 0.1];
for k = 1:3
    b(k).FaceColor = shades(k, :);
    b(k).DisplayName = sprintf('\\sigma = %g A', sigShow(k));
end
set(ax, 'XTickLabel', bands, 'YScale', 'log', 'YLim', [1e-3 1e3]);
styleAx(ax);
grid(ax, 'on');
ax.XGrid = 'off';
ax.GridAlpha = 0.15;
ylabel(ax, 'Median shift / clean IQR');
xlabel(ax, 'Sub-band');
title(ax, '(c) Feature shift under noise', 'FontWeight', 'normal', 'FontSize', 8.5);
legend(ax, 'Location', 'northwest', 'FontSize', 6.5, 'Box', 'off');
saveFig(fig, figDir, 'fig_cmp_importance');
end

%% ---------------------------------------------------------------- pipelines
function figPipelines(figDir)
fig = newFig(7.16, 2.5);
ax = axes(fig, 'Position', [0 0 1 1]);
hold(ax, 'on');
axis(ax, [0 100 0 36]);
axis(ax, 'off');
blue = [0.87 0.92 0.98];
orange = [0.99 0.91 0.85];
green = [0.85 0.95 0.90];
grey = [0.93 0.93 0.93];
purple = [0.93 0.89 0.97];
box(ax, 0.5, 13, 14, 10, grey, sprintf('Residual\n\\DeltaI = I_{phys} - I_{twin}\n3 x 667 samples'));
box(ax, 19, 24, 21, 10, orange, sprintf('db4 wavelet, 5 levels\n+ statistics\n87 handcrafted features'));
box(ax, 44, 24, 15, 10, orange, sprintf('RF / LightGBM\n/ SVM / MLP'));
box(ax, 19, 2, 21, 10, green, sprintf('Input scaling\nx / x_{ref}\nraw waveform kept'));
box(ax, 44, 2, 15, 10, green, sprintf('1D-CNN\n7 conv blocks\n703-sample view'));
box(ax, 63, 13, 11, 10, blue, sprintf('2-of-3 vote\nevery\n8.35 ms'));
box(ax, 77, 13, 10, 10, purple, sprintf('3I_0\ninterlock'));
box(ax, 90, 13, 9.5, 10, grey, sprintf('Breaker\n3 or 5\ncycles'));
arrow(ax, 14.5, 18, 19, 29);
arrow(ax, 14.5, 18, 19, 7);
arrow(ax, 40, 29, 44, 29);
arrow(ax, 40, 7, 44, 7);
arrow(ax, 59, 29, 63, 18);
arrow(ax, 59, 7, 63, 18);
arrow(ax, 74, 18, 77, 18);
arrow(ax, 87, 18, 90, 18);
text(ax, 39.5, 35.2, 'Feature-based route', 'FontSize', 8, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
text(ax, 39.5, 0.8, 'End-to-end route', 'FontSize', 8, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
saveFig(fig, figDir, 'fig_cmp_pipelines');
end

function box(ax, x, y, w, h, c, txt)
rectangle(ax, 'Position', [x y w h], 'Curvature', 0.08, 'FaceColor', c, 'EdgeColor', [0.35 0.35 0.35], 'LineWidth', 0.7);
text(ax, x + w / 2, y + h / 2, txt, 'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', 'FontSize', 7);
end

function arrow(ax, x1, y1, x2, y2)
plot(ax, [x1 x2], [y1 y2], 'Color', [0.25 0.25 0.25], 'LineWidth', 0.9);
a = atan2(y2 - y1, x2 - x1);
L = 1.2;
fill(ax, x2 - L * [0 cos(a - 0.45) cos(a + 0.45)], y2 - L * 2.6 * [0 sin(a - 0.45) sin(a + 0.45)] * 0.39, [0.25 0.25 0.25], 'EdgeColor', 'none');
end

%% ------------------------------------------------------------------ compute
function figCompute(out, figDir)
T = readtable(fullfile(out, 'compute_all.csv'), 'TextType', 'string');
pw = fileread(fullfile(out, 'compute_all_power.txt'));
onMains = ~contains(pw, 'Offline');
ids = ["svm", "mlp", "rf", "rf_aug", "lgbm", "lgbm_aug", "cnn_wide_ref", "cnn_wide_ref_aug"];
labs = {'SVM', 'MLP', 'RF', 'RF (noise)', 'LightGBM', 'LightGBM (noise)', 'CNN wide', 'CNN wide (noise)'};
feat = T.ClassifierMedian_ms(T.Model == "features");
[~, ix] = ismember(ids, T.Model);
clf = T.ClassifierMedian_ms(ix);
fe = feat * T.UsesWaveletFeatures(ix);
ref = 1;
unit = 'Median time per relay decision (ms)';
if ~onMains
    ref = feat;
    unit = 'Time per decision, relative to db4 feature extraction = 1';
end
fig = newFig(7.16, 2.6);
tl = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
ax = nexttile(tl);
b = barh(ax, [fe clf] / ref, 'stacked', 'BarWidth', 0.7, 'EdgeColor', 'none');
b(1).FaceColor = [0.60 0.60 0.60];
b(1).DisplayName = 'db4 feature extraction';
b(2).FaceColor = [0.165 0.471 0.839];
b(2).DisplayName = 'classifier';
set(ax, 'YTick', 1:numel(ids), 'YTickLabel', labs, 'YDir', 'reverse');
styleAx(ax);
grid(ax, 'on');
ax.YGrid = 'off';
ax.GridAlpha = 0.15;
xlabel(ax, unit);
title(ax, '(a) Compute time, one thread, MATLAB', 'FontWeight', 'normal', 'FontSize', 8.5);
legend(ax, 'Location', 'southeast', 'FontSize', 7, 'Box', 'off');
ax = nexttile(tl);
sz = T.InMemory_kB(ix);
barh(ax, sz, 0.7, 'FaceColor', [0.106 0.686 0.478], 'EdgeColor', 'none');
for k = 1:numel(ids)
    text(ax, sz(k) * 1.15, k, sprintf('%.0f kB', sz(k)), 'FontSize', 7, 'VerticalAlignment', 'middle');
end
set(ax, 'XScale', 'log', 'XLim', [10 2e5], 'YTick', 1:numel(ids), 'YTickLabel', {}, 'YDir', 'reverse');
styleAx(ax);
grid(ax, 'on');
ax.YGrid = 'off';
ax.GridAlpha = 0.15;
xlabel(ax, 'Classifier size in memory (kB, log scale)');
title(ax, '(b) Model size', 'FontWeight', 'normal', 'FontSize', 8.5);
saveFig(fig, figDir, 'fig_cmp_compute');
end

%% ----------------------------------------------------------------- training
function figTraining(ex, res, figDir)
fig = newFig(7.16, 2.8);
tl = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
ax = nexttile(tl);
hold(ax, 'on');
sets = {'cnn_ref', [0.537 0.529 0.506], 'CNN base, clean'; 'cnn_wide_ref', [0.55 0.82 0.70], 'CNN wide, clean'; 'cnn_wide_ref_aug', [0.106 0.686 0.478], 'CNN wide, noise-trained'};
for s = 1:size(sets, 1)
    runs = ex.cnn.(sets{s, 1});
    for r = 1:numel(runs)
        h = plot(ax, runs(r).es_loss, 'Color', sets{s, 2}, 'LineWidth', 1.1);
        if r == 1
            h.DisplayName = sets{s, 3};
        else
            h.HandleVisibility = 'off';
        end
    end
end
styleAx(ax);
grid(ax, 'on');
ax.GridAlpha = 0.15;
xlabel(ax, 'Epoch');
ylabel(ax, 'Early-stop (validation) loss');
title(ax, '(a) CNN training curves (3 seeds each)', 'FontWeight', 'normal', 'FontSize', 8.5);
legend(ax, 'Location', 'northeast', 'FontSize', 7, 'Box', 'off');

T = readtable(fullfile(res, 'scores_cv.csv'), 'TextType', 'string');
T = T(T.Stat == "pooled", :);
ids = ["cnn_slog", "cnn_ref", "cnn_wide_slog", "cnn_wide_ref", "rf", "lgbm"];
labs = {'CNN base, signed-log', 'CNN base, reference', 'CNN wide, signed-log', 'CNN wide, reference', 'RF', 'LightGBM'};
c = [0.72 0.72 0.70; 0.537 0.529 0.506; 0.55 0.82 0.70; 0.106 0.686 0.478; 0.165 0.471 0.839; 0.922 0.408 0.204];
ax = nexttile(tl);
hold(ax, 'on');
for k = 1:numel(ids)
    v = 100 * T.Dependability(T.Model == ids(k));
    barh(ax, k, v, 0.7, 'FaceColor', c(k, :), 'EdgeColor', 'none');
    text(ax, v + 1, k, sprintf('%.1f  (%d false trips)', v, T.FalseTrips(T.Model == ids(k))), 'FontSize', 7, 'VerticalAlignment', 'middle');
end
set(ax, 'YTick', 1:numel(ids), 'YTickLabel', labs, 'YDir', 'reverse', 'XLim', [0 135], 'XTick', 0:25:100);
styleAx(ax);
grid(ax, 'on');
ax.YGrid = 'off';
ax.GridAlpha = 0.15;
xlabel(ax, 'Fault detection, pooled cross-validation (%)');
title(ax, '(b) Architecture and scaling ablation', 'FontWeight', 'normal', 'FontSize', 8.5);
saveFig(fig, figDir, 'fig_cmp_training');
end
