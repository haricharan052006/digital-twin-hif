function outFile = make_briefing_pdf()
%MAKE_BRIEFING_PDF  Single PDF report of the digital-twin HIF relay project and
% the comparative model study: abstract, system and method, model comparison
% with statistics, noise study, learning curve, closed-loop clearing and
% interlock, compute footprint, conclusions and limitations. Most tables are
% read from the result files, so the report follows the data.
%
%   outFile = make_briefing_pdf()
%
% Inputs: results/dl/comparative/* (comparative_analysis.m, profile_all_relays.m),
%         results/dl/*.csv, results/report_figures/*.png
% Output: results/dl/briefing/HIF_Relay_Comparative_Report.pdf
% Requires: MATLAB Report Generator (mlreportgen.dom). Run headless:
% batch(parcluster, @make_briefing_pdf, 1, {}, 'AutoAttachFiles', false, ...)

import mlreportgen.dom.*
root = fileparts(fileparts(mfilename('fullpath')));
figDir = fullfile(root, 'results', 'report_figures');
res = fullfile(root, 'results', 'dl');
cmp = fullfile(res, 'comparative');
outBase = fullfile(res, 'briefing', 'HIF_Relay_Comparative_Report');
txt = {'TextType', 'string'};

TM = readtable(fullfile(cmp, 'test_metrics.csv'), txt{:});
BM = readtable(fullfile(cmp, 'bootstrap_models.csv'), txt{:});
BP = readtable(fullfile(cmp, 'bootstrap_pairs.csv'), txt{:});
SC = readtable(fullfile(cmp, 'scorecard.csv'), txt{:});
CF = readtable(fullfile(cmp, 'class_f1.csv'), txt{:});
NG = readtable(fullfile(cmp, 'noise_grid.csv'), txt{:});
SG = readtable(fullfile(cmp, 'subgroup_cv.csv'), txt{:});
CC = readtable(fullfile(cmp, 'closed_loop_cases.csv'), txt{:});
FG = readtable(fullfile(cmp, 'feature_groups.csv'), txt{:});
CP = readtable(fullfile(cmp, 'compute_all.csv'), txt{:});
LC = readtable(fullfile(res, 'learning_curve_summary.csv'), txt{:});
CV = readtable(fullfile(res, 'scores_cv.csv'), txt{:});
W = readtable(fullfile(root, 'data', 'dl', 'windows.csv'), txt{:});
power = fileread(fullfile(cmp, 'compute_all_power.txt'));

d = Document(outBase, 'pdf');
open(d);
pl = d.CurrentPageLayout;
pl.PageSize.Height = '11.69in';
pl.PageSize.Width = '8.27in';
pl.PageMargins.Top = '0.75in';
pl.PageMargins.Bottom = '0.75in';
pl.PageMargins.Left = '0.85in';
pl.PageMargins.Right = '0.85in';
pl.PageMargins.Header = '0.3in';
pl.PageMargins.Footer = '0.35in';
footer = PDFPageFooter('default');
fp = Paragraph();
fp.Style = {HAlign('center'), FontSize('8.5pt'), Color('#6b7480'), FontFamily('Arial')};
append(fp, Text('Digital-twin HIF relay: comparative study - page '));
append(fp, Page());
append(footer, fp);
pl.PageFooters = footer;
counter('reset');

%% ------------------------------------------------------------ title, abstract
para(d, 'IEEE 13-BUS DIGITAL-TWIN HIF PROTECTION  |  COMPARATIVE STUDY', ...
    {Bold(true), FontSize('9pt'), Color('#1d5ea8'), OuterMargin('0pt', '0pt', '0pt', '6pt')});
para(d, 'Digital-Twin High-Impedance Fault Protection on the IEEE 13-Bus Feeder: Wavelet-Feature and End-to-End Relays Compared', ...
    {Bold(true), FontSize('19pt'), Color('#12171d'), OuterMargin('0pt', '0pt', '0pt', '8pt')});
para(d, 'Project report  |  31 October 2026', {FontSize('9.5pt'), Color('#6b7480'), OuterMargin('0pt', '0pt', '0pt', '10pt')});

heading(d, 'Abstract');
para(d, abstractText(), {});
p = Paragraph();
k = Text('Keywords: ');
k.Style = {Bold(true)};
append(p, k);
append(p, Text(['high-impedance fault, digital twin, IEEE 13-bus feeder, Emanuel arc model, discrete wavelet transform, ' ...
    'LightGBM, random forest, 1D-CNN, measurement noise, fault-clearing time, zero-sequence interlock']));
p.Style = {FontFamily('Arial'), FontSize('9pt'), Color('#1f2933'), OuterMargin('0pt', '0pt', '2pt', '8pt')};
append(d, p);

heading(d, 'Main findings');
bullets(d, {
    'Best on clean signals:', ' LightGBM on the 87 wavelet features (97.1 % fault detection, 2 false trips of 360). Its fault-detection lead over the deployed RF and over the CNN is statistically significant.'
    'Best under strong noise:', ' the noise-trained wide CNN (91 % fault detection and 92 % weak-arc detection at 0.1 A; 89 % and 88 % at 0.2 A).'
    'Noise training is essential:', ' any model trained only on clean signals loses reliability under noise. Clean-trained LightGBM jumps from 2 to about 26 false trips at just 5 mA.'
    'Why the CNN lags on clean signals:', ' mainly too little training data. The trees level off by about 360 runs, while the CNN is still improving at 720.'
    'Clearing time:', ' dominated by the breaker. Medians are 80-84 ms with a 3-cycle and 113-117 ms with a 5-cycle breaker for the clean-trained relays; the relay changes the median by at most 4 ms.'
    'Selectivity:', ' a 3I0 interlock removes all 64 healthy-lateral trips across 288 fault runs without changing any fault trip time.'});

%% ------------------------------------------------------------ 1 system, method
pageBreak(d);
heading(d, '1. System and method');
para(d, ['The test system is the unbalanced 4.16 kV IEEE 13-node feeder, modelled in Simscape Electrical (Specialized Power ' ...
    'Systems) with a discrete 50 µs solver. Emanuel-arc HIF branches can be switched in on any phase at buses 633 and 675. ' ...
    'Capacitor switching and load steps act as decoys. A healthy digital twin runs in parallel in the same simulation, and the ' ...
    'relay at each lateral head sees the residual between the measured and twin currents.'], {});
figure_(d, fullfile(figDir, 'fig_oneline_ieee13.png'), ...
    'Feeder as modelled: protected laterals 632-633-634 and 692-675, their breakers and meters, HIF locations and switching decoys.', 4.0);
figure_(d, fullfile(figDir, 'fig_arc_characteristic.png'), ...
    'Emanuel arc model: v-i characteristic and arc current for the typical and the weak (near-limit) arc used in the verification cases.', 2.9);
pageBreak(d);
figure_(d, fullfile(figDir, 'fig_cmp_pipelines.png'), ...
    ['The two relay routes compared in this study. Both share the same two-cycle window, 2-of-3 vote, interlock and breaker; ' ...
     'only the decision stage differs.'], 2.0);
figure_(d, fullfile(figDir, 'fig_cmp_model_canvas.png'), ...
    ['Top level of the closed-loop Simulink model: physical feeder, digital twin, residuals, the two HIF relays, the relay ' ...
     'interlock, breaker-delay blocks and the operator controls.'], 3.0);

cls = ["Normal", "Switching_Transient", "HIF_Phase_A", "HIF_Phase_B", "HIF_Phase_C"];
rows = cell(numel(cls) + 1, 4);
for c = 1:numel(cls)
    a = nnz(W.label == cls(c) & W.split == "train");
    b = nnz(W.label == cls(c) & W.split == "test");
    rows(c, :) = {char(strrep(cls(c), '_', ' ')), sprintf('%d', a), sprintf('%d', b), sprintf('%d', a + b)};
end
rows(end, :) = {'All windows', sprintf('%d', nnz(W.split == "train")), sprintf('%d', nnz(W.split == "test")), sprintf('%d', height(W))};
table(d, {'Class', 'Training (720 runs)', 'Held-out test (180 runs)', 'Total'}, rows, ...
    'Dataset: two-cycle windows (667 samples at 20 kHz) from 900 runs, including 150 weak near-limit arc runs. Windows of one run are never split across training and test.', ...
    {'34%', '22%', '26%', '18%'}, 'Dataset');
table(d, {'Model', 'Input', 'Configuration', 'Trained on'}, {
    'RF (deployed relay)', '87 db4 features', '100 bagged trees', 'clean; clean + noise'
    'LightGBM', '87 db4 features', 'learning rate 0.05, 31 leaves, early stopping, 3 seeds', 'clean; clean + noise'
    'SVM', '87 db4 features', 'ECOC, Gaussian kernel', 'clean'
    'MLP', '87 db4 features', 'two hidden layers (50, 30), ReLU', 'clean'
    'CNN base', 'raw 3 x 667 window', '4 conv blocks, 26,421 params, 63-sample view, 3 seeds', 'clean'
    'CNN wide', 'raw 3 x 667 window', '7 conv blocks, 30,645 params, 703-sample view, 3 seeds', 'clean; clean + noise'}, ...
    'Fault detection = 2-of-3 vote over each faulted lateral. False trips = run/lateral sequences where the vote fires without a fault on that lateral (360 test sequences).', ...
    {'20%', '18%', '42%', '20%'}, 'Models');

%% ----------------------------------------------------------- 2 which is better
heading(d, '2. Which model is better? Results on the 180 held-out test runs');
para(d, 'No single model wins everywhere. The scorecard shows the best model per criterion.', {});
table(d, {'Criterion', 'Best model', 'Value'}, cellstr(SC{:, :}), ...
    ['"(noise)" = trained with noise. False-trip criteria only count relays detecting at least half of the faults at that noise ' ...
     'level. The MLP leads weak-arc detection on clean signals but makes 21 false trips.'], {'46%', '36%', '18%'}, 'Scorecard');
figure_(d, fullfile(figDir, 'fig_cmp_overall.png'), ...
    ['All models on clean test signals. Light bars: clean-trained; solid bars: noise-trained; grey: the original narrow CNN. ' ...
     'Error bars: seed spread in (a), 95 % run-level bootstrap interval in (b) and (c).'], 3.3);

n = height(TM);
rows = cell(n, 10);
for k = 1:n
    rows(k, :) = {char(TM.Label(k)), f1(100 * TM.Accuracy(k)), sprintf('%.3f', TM.MacroF1(k)), f1(100 * TM.HifPrecision(k)), ...
        f1(100 * TM.HifRecall(k)), sprintf('%.4f', TM.AUC(k)), f1(100 * TM.Dependability(k)), f1(100 * TM.DependabilityWeak(k)), ...
        f1(100 * TM.Security(k)), f1(TM.FalseTrips(k))};
end
table(d, {'Model', 'Accur. %', 'Macro F1', 'HIF prec. %', 'HIF recall %', 'AUC', 'Fault det. %', 'Weak det. %', 'Secur. %', 'False trips'}, rows, ...
    'Window-level accuracy, macro F1, HIF-vs-rest precision, recall and AUC; run-level fault detection, weak-arc detection, security and false trips. Mean over seeds. Source: results/dl/comparative/test_metrics.csv.', ...
    {'21%', '8%', '8%', '9%', '9%', '9%', '9%', '9%', '9%', '9%'}, 'Full test-set metrics');

rows = cell(height(CF), 7);
for k = 1:height(CF)
    rows(k, :) = {char(CF.Label(k)), sprintf('%.3f', CF.F1_Normal(k)), sprintf('%.3f', CF.F1_Switching(k)), sprintf('%.3f', CF.F1_HIF_A(k)), ...
        sprintf('%.3f', CF.F1_HIF_B(k)), sprintf('%.3f', CF.F1_HIF_C(k)), f1(100 * CF.R_Switching(k))};
end
table(d, {'Model', 'F1 Normal', 'F1 Switching', 'F1 HIF A', 'F1 HIF B', 'F1 HIF C', 'Switching recall %'}, rows, ...
    'Per-class results, window level. Every model finds switching transients hardest; the CNN often calls them Normal, which costs macro F1 but does not cause trips.', ...
    {'24%', '12%', '13%', '12%', '12%', '12%', '15%'}, 'Per-class F1');
figure_(d, fullfile(figDir, 'fig_cmp_confusion.png'), ...
    'Row-normalised confusion matrices (%), mean over seeds. Most errors are HIF windows called Normal; choosing the wrong faulted phase is rare except for the clean-trained CNN.', 3.6);
figure_(d, fullfile(figDir, 'fig_cmp_roc.png'), ...
    'ROC curves for HIF windows vs the rest, deployed seed of each model; AUC in the legend. Trees lead without noise; at 0.1 A the noise-trained models lead and the clean-trained trees fall away. SVM scores are a ranking only.', 3.7);

ids = ["svm", "mlp", "rf", "lgbm", "cnn_ref", "cnn_wide_ref", "rf_aug", "lgbm_aug", "cnn_wide_ref_aug"];
rows = cell(numel(ids), 5);
for k = 1:numel(ids)
    a = BM(BM.Model == ids(k) & BM.Sigma_A == 0, :);
    b = BM(BM.Model == ids(k) & BM.Sigma_A == 0.1, :);
    rows(k, :) = {char(a.Label), ci(a.Dep, a.Dep_lo, a.Dep_hi), ci(a.Weak, a.Weak_lo, a.Weak_hi), ci(b.Dep, b.Dep_lo, b.Dep_hi), ci(b.Weak, b.Weak_lo, b.Weak_hi)};
end
table(d, {'Model', 'Fault detection, no noise', 'Weak-arc, no noise', 'Fault detection, 0.1 A', 'Weak-arc, 0.1 A'}, rows, ...
    'Percent, with 95 % bootstrap interval from resampling whole test runs (5000 draws). Intervals reflect the finite test set, not training randomness.', ...
    {'24%', '19%', '19%', '19%', '19%'}, 'Confidence intervals');

rows = cell(height(BP), 5);
for k = 1:height(BP)
    if BP.Sigma_A(k) == 0
        noiseLbl = 'none';
    elseif BP.Sigma_A(k) < 0.1
        noiseLbl = sprintf('%g mA', 1e3 * BP.Sigma_A(k));
    else
        noiseLbl = sprintf('%g A', BP.Sigma_A(k));
    end
    rows(k, :) = {noiseLbl, sprintf('%s vs %s', BP.ModelA(k), BP.ModelB(k)), dci(BP.dDep(k), BP.dDep_lo(k), BP.dDep_hi(k)), ...
        dci(BP.dWeak(k), BP.dWeak_lo(k), BP.dWeak_hi(k)), dci(BP.dFT(k), BP.dFT_lo(k), BP.dFT_hi(k))};
end
table(d, {'Noise', 'Comparison (A vs B)', 'Fault detection, points', 'Weak-arc, points', 'False trips'}, rows, ...
    'Difference A minus B with 95 % bootstrap interval. * = interval excludes zero (statistically significant). At 0.1 A the CNN''s lead over noise-trained LightGBM is significant for weak arcs but not for overall detection; at 50 mA the two are not significantly different.', ...
    {'8%', '38%', '20%', '19%', '15%'}, 'Pairwise significance');

%% --------------------------------------------------------- 3 CNN design
heading(d, '3. CNN design: receptive field and input scaling');
para(d, ['The first CNN saw only 63 samples (0.19 cycle), too short to compare the arc''s two half-cycles. Widening the view to 703 ' ...
    'samples (2.1 cycles) at about the same parameter count adds 19-21 points of fault detection in both input scalings. Linear ' ...
    'reference scaling beats signed-log scaling, which overfits. A training check confirmed healthy gradients and activations, so ' ...
    'this is a design effect, not a pipeline fault.'], {});
figure_(d, fullfile(figDir, 'fig_cmp_training.png'), ...
    'CNN validation loss during training, showing the lower loss of the wide and noise-trained networks, and the 2 x 2 ablation of architecture and scaling in cross-validation, with RF and LightGBM for reference.', 2.8);
ids = ["rf", "lgbm", "cnn_wide_ref", "cnn_wide_slog", "cnn_ref", "cnn_slog"];
labs = {'RF', 'LightGBM', 'CNN wide, reference', 'CNN wide, signed-log', 'CNN base, reference', 'CNN base, signed-log'};
rows = cell(numel(ids), 5);
for k = 1:numel(ids)
    a = CV(CV.Model == ids(k) & CV.Stat == "pooled", :);
    b = CV(CV.Model == ids(k) & CV.Stat == "fold std", :);
    rows(k, :) = {labs{k}, sprintf('%.3f ± %.3f', a.MacroF1, b.MacroF1), sprintf('%.1f ± %.1f', 100 * a.Dependability, 100 * b.Dependability), ...
        sprintf('%.1f ± %.1f', 100 * a.DependabilityWeak, 100 * b.DependabilityWeak), sprintf('%d', a.FalseTrips)};
end
table(d, {'Model', 'Macro F1', 'Fault detection %', 'Weak-arc %', 'False trips / 1,440'}, rows, ...
    'Five-fold run-grouped cross-validation on the 720 training runs: pooled value ± spread across folds.', {'30%', '20%', '19%', '16%', '15%'}, 'Cross-validation');

%% ----------------------------------------------------- 4 where models fail
heading(d, '4. Where each model struggles');
figure_(d, fullfile(figDir, 'fig_cmp_subgroups.png'), ...
    'Fault detection by arc strength, faulted phase, lateral and dataset (clean-trained models, out-of-fold cross-validation predictions). n = number of fault sequences.', 2.8);
labels = {'Arc resistance < 1235 Ohm', 'Arc resistance 1235-1801 Ohm', 'Arc resistance > 1801 Ohm', 'Breakdown voltage < 1597 V', ...
    'Breakdown voltage 1597-2198 V', 'Breakdown voltage > 2198 V', 'Phase A', 'Phase B', 'Phase C', 'Lateral 633', 'Lateral 675', 'Main dataset', 'Weak-arc dataset'};
rows = cell(numel(labels), 6);
vals = SG{:, 2:end};
for g = 1:numel(labels)
    rows(g, :) = {labels{g}, sprintf('%d', vals(5, g)), f1(vals(1, g)), f1(vals(2, g)), f1(vals(3, g)), f1(vals(4, g))};
end
table(d, {'Group', 'Sequences', 'RF %', 'LightGBM %', 'CNN wide %', 'CNN base %'}, rows, ...
    ['Harder arcs have high resistance and high breakdown voltage. Lateral 675 is harder for every model, most of all the CNN (46 % against 96 %). ' ...
     'A likely reason, not yet tested, is its heavier load and capacitor bank, which give larger normal residuals.'], ...
    {'34%', '14%', '13%', '13%', '13%', '13%'}, 'Detection by subgroup');
figure_(d, fullfile(figDir, 'fig_cmp_false_trips.png'), ...
    'What the false trips are. Without noise nearly all are votes on the healthy neighbouring lateral, the kind the interlock removes. Clean-trained models also start tripping on normal runs under noise.', 2.7);

%% ------------------------------------------------------------- 5 noise
heading(d, '5. Measurement noise');
para(d, ['Real measurements carry random error from sensors and electronics, while the simulation has none. To test this, white ' ...
    'Gaussian noise of fixed standard deviation (sigma) is added per phase to the held-out test windows. Two questions matter: ' ...
    'is there noise at test time, and did the model see noise during training? For noise training, RF, LightGBM and the wide CNN ' ...
    'used the clean training windows plus two noisy copies of each, with sigma drawn log-uniformly from 5 mA to 0.1 A. SVM and MLP ' ...
    'were trained on clean signals only, so they compare with the clean-trained models.'], {});
figure_(d, fullfile(figDir, 'fig_cmp_noise_grid.png'), ...
    'All models against noise level. Darker blue is better detection; darker red is more false trips. Grey in (c) marks a relay that detects no faults at that noise level, so its zero false trips mean nothing.', 3.2);
figure_(d, fullfile(figDir, 'fig_dl_noise_augmented.png'), ...
    'Clean-trained (dashed, open markers) and noise-trained (solid) RF, LightGBM and wide CNN against noise level. Error bars: spread over three seeds.', 5.2);
keep = ["svm", "mlp", "rf", "lgbm", "cnn_wide_ref", "rf_aug", "lgbm_aug", "cnn_wide_ref_aug"];
sig = [0 0.02 0.05 0.1 0.2];
rows = cell(numel(keep), 6);
for k = 1:numel(keep)
    r = NG(NG.Model == keep(k), :);
    rows{k, 1} = char(r.Label(1));
    for s = 1:numel(sig)
        q = r(abs(r.Sigma_A - sig(s)) < 1e-9, :);
        rows{k, s + 1} = sprintf('%.0f / %.0f / %.0f', 100 * q.Dependability, 100 * q.DependabilityWeak, q.FalseTrips);
    end
end
table(d, {'Model', 'No noise', '20 mA', '50 mA', '0.1 A', '0.2 A'}, rows, ...
    'Each cell: fault detection % / weak-arc detection % / false trips of 360. Source: results/dl/comparative/noise_grid.csv.', ...
    {'25%', '15%', '15%', '15%', '15%', '15%'}, 'Noise sweep');
subheading(d, 'Why do the wavelet models suffer? The evidence');
para(d, ['White noise spreads across all frequencies, including high-frequency bands that are almost empty in a healthy signal ' ...
    '(microamps in D1, see the wavelet figure below). So even 5 mA moves the D1 features by 2.5 times their normal spread, while the ' ...
    'low-frequency A5 features barely move. Clean-trained trees depend heavily on D1, D2 and entropy features. Noise training ' ...
    'makes them abandon those bands and rely on time-domain statistics and low-frequency bands instead, which is why they recover, ' ...
    'at the price of some weak-arc detection on clean signals. The CNN sees the waveform over two cycles, where random error tends to average ' ...
    'out; that part remains a likely explanation, not a tested one.'], {});
figure_(d, fullfile(figDir, 'fig_cmp_importance.png'), ...
    'What the tree models rely on: share of importance by wavelet band (a) and by statistic (b), clean-trained vs noise-trained. (c) How far noise moves each feature group on Normal test windows (median shift divided by the clean interquartile range).', 2.9);
rows = cell(height(FG), 8);
for k = 1:height(FG)
    rows(k, :) = {char(FG.Band(k)), f1(FG.RF_clean(k)), f1(FG.RF_noise(k)), f1(FG.LGBM_clean(k)), f1(FG.LGBM_noise(k)), ...
        sprintf('%.3g', FG.Shift_5mA(k)), sprintf('%.3g', FG.Shift_50mA(k)), sprintf('%.3g', FG.Shift_100mA(k))};
end
table(d, {'Band', 'RF clean %', 'RF noise %', 'LGBM clean %', 'LGBM noise %', 'Shift, 5 mA', 'Shift, 50 mA', 'Shift, 0.1 A'}, rows, ...
    'Importance share per wavelet sub-band (A5 lowest frequency, D1 highest; time = time-domain moments, cross = cross-phase) and feature shift under noise.', ...
    {'10%', '12%', '12%', '14%', '14%', '13%', '13%', '12%'}, 'Feature importance and noise shift');
figure_(d, fullfile(figDir, 'fig_wavelet_decomposition.png'), ...
    'db4 five-level decomposition of the lateral-633 residual, healthy window (left) and fault window (right). Note the scales: the healthy high-frequency bands are extremely small, so a little noise dominates them.', 5.4);

%% ---------------------------------------------------------- 6 learning curve
heading(d, '6. Learning curve: is the CNN short of data?');
para(d, ['Each model was retrained on nested subsets of the 720 training runs and tested on the same 180 runs. The trees gain little ' ...
    'beyond about 360 runs, because the wavelet features already encode the physics. The CNN is still improving at 720 runs. A power law ' ...
    'fitted to its missed-fault rate reaches LightGBM''s 97.1 % at roughly 13,000 runs, about 18 times the current set; this is a long ' ...
    'extrapolation from four points, so it is only an order of magnitude. The same fit predicts 89.9 % at three times the data, and the ' ...
    'two noisy copies per window, which triple the training windows, gave 90.6 %.'], {});
figure_(d, fullfile(figDir, 'fig_dl_learning_curve.png'), ...
    'Learning curve (mean ± sd of three repeats). The star marks the noise-trained wide CNN (720 runs, two noisy copies per window), drawn slightly to the right.', 2.8);
mods = ["rf", "lgbm", "cnn_wide_ref"];
names = {'Random Forest', 'LightGBM', 'CNN wide'};
fr = [25 50 75 100];
rows = cell(numel(mods), 5);
for k = 1:numel(mods)
    rows{k, 1} = names{k};
    for j = 1:4
        q = LC(LC.Model == mods(k) & LC.Fraction == fr(j), :);
        rows{k, j + 1} = sprintf('%.1f ± %.1f', 100 * q.Dependability, 100 * q.Dependability_std);
    end
end
table(d, {'Fault detection %', '183 runs', '362 runs', '543 runs', '720 runs'}, rows, ...
    'Nested subsets stratified by event type and dataset. Source: results/dl/learning_curve_summary.csv.', {'24%', '19%', '19%', '19%', '19%'}, 'Learning curve');

%% ------------------------------------------------------------ 7 closed loop
heading(d, '7. Closed-loop fault clearing and isolation');
para(d, ['Each relay runs inside the Simulink model and its trip opens the lateral breaker in both the feeder and the twin. Runs cover 8 HIF ' ...
    'cases at 4 inception instants and 4 decoy cases, with breaker operating times of 0, 3 and 5 cycles. Timeline: t0 inception, t1 first ' ...
    'HIF decision, t2 trip asserted (2-of-3 latch), t3 contacts part (t2 + breaker time), t4 arc extinguished at current zero, t5 isolation ' ...
    'confirmed (lateral current and residual below 0.05 A for one cycle). SVM and MLP were not run in the closed loop. The twin has no ' ...
    'measurement noise, so these runs check timing and selectivity, not noise tolerance.'], {});
figure_(d, fullfile(figDir, 'fig_dl_clearing_times.png'), ...
    'Fault-clearing time of every run for the clean-trained relays at 0, 3 and 5 cycles (bar = median), and the median stage breakdown with a 3-cycle breaker (sum of stage medians).', 3.3);
table(d, {'Relay', 'Cleared', 'Trip t2-t0', 'Clear t4-t0, 3 cyc', 'Isolation t5-t0', 'Clear, 0 / 5 cyc'}, {
    'RF',        '30 / 32', '27.3 (12.7-58.6)', '83.9 (68.7-115.6)', '99.5 (128.3)', '33.9 / 117.3'
    'LightGBM',  '32 / 32', '26.3 (14.8-48.2)', '83.9 (67.7-105.0)', '97.8 (120.7)', '33.9 / 117.3'
    'CNN wide',  '32 / 32', '24.2 (16.9-33.6)', '79.9 (71.1-94.5)',  '95.7 (104.0)', '29.9 / 113.2'}, ...
    ['All times in ms. Clean-trained relays, no interlock. Trip and clearing: median (range); isolation: median (max); last column: median ' ...
     'clearing with a 0- and a 5-cycle breaker. With a 3-cycle breaker the medians are 5.0, 5.0 and 4.8 cycles.'], ...
    {'13%', '11%', '19%', '21%', '17%', '19%'}, 'Clearing time, clean-trained relays');
figure_(d, fullfile(figDir, 'fig_dl_clearing_example.png'), ...
    '633A typical arc, 3-cycle breaker: arc current (red), lateral-633 phase currents (grey) and the protection timeline for each clean-trained relay.', 3.9);
figure_(d, fullfile(figDir, 'fig_cmp_closed_loop.png'), ...
    'Clean-trained vs noise-trained relays in the closed loop (3-cycle breaker, interlock on): clearing time of every run, and median trip time per fault case. Noise-trained trees trip earlier on typical arcs but later on weak ones.', 3.3);
relays = ["RF", "LightGBM", "CNN wide", "RF noise-trained", "LightGBM noise-trained", "CNN wide noise-trained"];
cases = ["633A typical", "633B typical", "633C typical", "675A typical", "675B typical", "675C typical", "633B weak", "675C weak"];
rows = cell(numel(relays), numel(cases) + 1);
for a = 1:numel(relays)
    rows{a, 1} = char(relays(a));
    for c = 1:numel(cases)
        q = CC(CC.Relay == relays(a) & CC.Case == cases(c), :);
        if isnan(q.TripMedian_ms)
            rows{a, c + 1} = 'miss';
        elseif q.Missed_of_4 > 0
            rows{a, c + 1} = sprintf('%.1f*', q.TripMedian_ms);
        else
            rows{a, c + 1} = sprintf('%.1f', q.TripMedian_ms);
        end
    end
end
table(d, {'Relay', '633A', '633B', '633C', '675A', '675B', '675C', '633B weak', '675C weak'}, rows, ...
    'Median trip time (ms) per fault case over four inception instants, 3-cycle breaker, interlock on. * = 2 of 4 runs missed; miss = all 4 missed.', ...
    {'28%', '9%', '9%', '9%', '9%', '9%', '9%', '9%', '9%'}, 'Trip time per fault case');
table(d, {'Noise-trained relay', 'Cleared', 'Healthy trips', 'Trip t2-t0', 'Clear t4-t0'}, {
    'RF, noise-trained',        '28 / 32', '0', '16.9 (8.5-75.3)',  '73.0 (64.8-131.4)'
    'LightGBM, noise-trained',  '32 / 32', '0', '18.9 (8.5-58.6)',  '77.0 (64.8-115.6)'
    'CNN wide, noise-trained',  '32 / 32', '0', '25.2 (14.8-48.1)', '81.1 (70.9-105.0)'}, ...
    '3-cycle breaker, interlock on; times in ms, median (range). The noise-trained RF misses the weak 675C arc at all four inception instants.', ...
    {'30%', '13%', '19%', '19%', '19%'}, 'Noise-trained relays in the closed loop');
subheading(d, 'Inter-relay interlock');
para(d, ['Without coordination a fault on one lateral can also trip the healthy neighbour. The interlock grants the first relay to trip ' ...
    'and blocks its neighbour for the breaker time plus 60 ms, resetting the blocked relay every step. Same-tick ties go to the lateral ' ...
    'with the larger zero-sequence (3I0) residual energy, because an HIF is a ground fault. A first version using total residual energy ' ...
    'picked the healthy lateral in 6 of 12 ties, since a weak arc carries less current than the neighbour''s response to the voltage sag.'], {});
table(d, {'Relay', 'Healthy-lateral trips, no interlock', 'With interlock', 'Fault trip times'}, {
    'RF',        '0 / 4 / 4',     '0 / 0 / 0', 'unchanged'
    'LightGBM',  '1 / 4 / 5',     '0 / 0 / 0', 'unchanged'
    'CNN wide',  '14 / 16 / 16',  '0 / 0 / 0', 'unchanged'}, ...
    'Healthy-lateral trips with breaker times of 0 / 3 / 5 cycles (288 fault runs, 12 decoy runs). No decoy run tripped. Source: results/dl/interlock_comparison.csv.', ...
    {'16%', '38%', '23%', '23%'}, 'Effect of the interlock');

%% ---------------------------------------------------------------- 8 compute
heading(d, '8. Compute footprint');
figure_(d, fullfile(figDir, 'fig_cmp_compute.png'), ...
    'Compute time per decision relative to db4 feature extraction, measured with all models back to back on the same 1000 test windows, one thread, in MATLAB; and classifier size in memory.', 2.6);
ids = ["svm", "mlp", "rf", "rf_aug", "lgbm", "lgbm_aug", "cnn_wide_ref", "cnn_wide_ref_aug"];
labs = {'SVM', 'MLP', 'RF', 'RF (noise)', 'LightGBM', 'LightGBM (noise)', 'CNN wide', 'CNN wide (noise)'};
mains = {'-', '-', '2.17', '-', '2.29', '-', '0.41', '-'};
feat = CP.ClassifierMedian_ms(CP.Model == "features");
rows = cell(numel(ids), 5);
for k = 1:numel(ids)
    q = CP(CP.Model == ids(k), :);
    useF = 'no';
    if q.UsesWaveletFeatures
        useF = 'yes';
    end
    rows(k, :) = {labs{k}, useF, sprintf('%.2f', q.DecisionMedian_ms / feat), sprintf('%.0f', q.InMemory_kB), mains{k}};
end
if contains(power, 'Offline')
    pwrNote = ['The relative times were measured on battery, when the laptop ran about 8 times slower than in earlier runs; ratios stay valid but ' ...
        'absolute times do not. Last column: earlier full-speed runs (db4 extraction 1.92 ms); RF, LightGBM and the CNN fit the 8.35 ms decision interval at p99 in those runs.'];
else
    pwrNote = 'Measured on mains power. Last column: earlier full-speed runs for comparison; decision interval 8.35 ms.';
end
table(d, {'Model', 'Needs db4 stage', 'Decision time (db4 = 1)', 'Size in memory (kB)', 'Earlier run (ms)'}, rows, pwrNote, ...
    {'28%', '17%', '21%', '19%', '15%'}, 'Compute footprint');
para(d, ['In interpreted MATLAB the CNN is about five times faster because it has no wavelet stage. By operation count the wavelet route is ' ...
    'lighter (about 0.1 M operations by our estimate against 2 M for the CNN), so it should be cheaper on compiled firmware; this is not measured.'], {});

%% -------------------------------------------------------------- conclusions
heading(d, '9. Conclusions: which relay for which condition');
table(d, {'Condition', 'Recommended relay', 'Evidence (test set unless noted)'}, {
    'Almost no noise (ideal signal)', 'LightGBM, clean-trained', '97.1 % fault detection, 90.5 % weak-arc, 2 false trips; but about 26 false trips at only 5 mA'
    'Low noise (5-20 mA)', 'LightGBM, noise-trained', '92-93 % detection, 2-3 false trips (clean-trained at 20 mA: similar detection, 21 false trips)'
    'Medium noise (about 50 mA)', 'LightGBM or CNN, both noise-trained', 'no significant difference overall (93 % vs 91 %); CNN if weak arcs are the priority (90 % vs 81 %)'
    'High noise (0.1-0.2 A)', 'CNN wide, noise-trained', '91 % / 92 % at 0.1 A and 89 % / 88 % at 0.2 A (detection / weak-arc)'
    'Any condition', 'Add the 3I0 interlock', 'healthy-lateral trips 64 to 0, trip times unchanged'}, ...
    'SVM and MLP are not recommended: weaker overall on clean signals, and they collapse under noise (trained on clean signals only).', ...
    {'26%', '26%', '48%'}, 'Selection guide');
bullets(d, {
    'End-to-end learning does not replace the wavelet front end outright.', ' On clean signals wavelet features + LightGBM are the most accurate; closing the CNN''s gap by simulation alone would need about ten times more runs.'
    'The CNN earns its place where the signal is noisy,', ' especially for weak arcs, which is the hardest protection case.'
    'Clearing time is set mostly by the breaker;', ' the relay still decides whether a weak arc is caught at all, and how quickly.'});
subheading(d, 'Limitations');
bullets(d, {
    'Simulation only:', ' one IEEE 13-bus feeder and one arc model; no field data or relay hardware.'
    'Target not reached:', ' the 99.41 % window-accuracy target was not met; the best is 98.4 % (LightGBM).'
    'Noise model:', ' white Gaussian noise on the residual only, trained up to 0.1 A; no CT saturation or measurement-chain harmonics, and the closed loop is noise-free.'
    'Statistics:', ' only 28 weak-arc test sequences, three seeds per model, 8 fixed arcs in the closed loop.'
    'Breaker and interlock:', ' fixed operating time with current-zero interruption, no restrike or reclosing; the interlock assumes one fault at a time and its tie-break rests on 4 distinct tie situations.'});
subheading(d, 'Points for discussion');
bullets(d, {
    'Target venue', ' - sets the paper length and which figures to keep.'
    'Realistic noise level at the relay', ' - decides which relay the paper recommends.'
    'Next step', ' - hybrid wavelet + CNN relay, a noisy closed-loop study, or start writing.'});

close(d);
outFile = [outBase '.pdf'];
fprintf('Saved %s with %d figures and %d tables\n', outFile, counter('fig'), counter('tab'));
end

%% ======================================================================
function t = abstractText()
t = ['High-impedance faults (HIFs) on distribution feeders draw too little current for conventional overcurrent protection ' ...
    'to detect them. This work develops and evaluates a digital-twin relay for the unbalanced 4.16 kV IEEE 13-bus feeder, modelled in ' ...
    'Simscape Electrical with randomised Emanuel-arc faults and switching decoys. A healthy twin runs in parallel with the feeder, and the ' ...
    'differential residual at each lateral head is classified over two-cycle windows, with a 2-of-3 vote before tripping. Using 900 ' ...
    'simulated runs and run-grouped validation, wavelet-feature classifiers (Random Forest, LightGBM, SVM and MLP) are compared with an ' ...
    'end-to-end 1D-CNN on the raw residual. On noise-free signals LightGBM performs best, detecting 97.1 % of faults on held-out runs ' ...
    'with 2 false trips in 360 sequences, ahead of the Random Forest (89.3 %); the best clean-trained CNN reaches 78.6 %, and a learning curve indicates that this gap ' ...
    'is mainly due to limited training data. Under measurement noise the ranking changes: with noise-augmented training, the CNN ' ...
    'keeps about 90 % fault and weak-arc detection up to 0.2 A per phase, while the weak-arc detection of the tree models falls from 0.1 A, ' ...
    'consistent with noise corrupting the high-frequency wavelet bands they rely on. In closed-loop simulation with 3- and 5-cycle ' ...
    'breakers, median clearing times of the clean-trained relays are 80-84 ms and 113-117 ms, dominated by the breaker operating time. Relays without ' ...
    'coordination also tripped the healthy lateral; a proposed inter-relay interlock with a zero-sequence tie-break removed all 64 ' ...
    'such trips across 288 fault runs without changing any fault trip time. The results suggest choosing the relay according to the measurement ' ...
    'noise level, with the interlock in all cases. All results are from simulation.'];
end

function s = f1(v)
s = sprintf('%.1f', v);
end

function s = ci(v, lo, hi)
s = sprintf('%.1f (%.1f-%.1f)', v, lo, hi);
end

function s = dci(v, lo, hi)
sig = '';
if lo > 1e-6 || hi < -1e-6
    sig = '*';
end
s = sprintf('%+.1f (%.1f, %.1f)%s', round(v, 1) + 0, round(lo, 1) + 0, round(hi, 1) + 0, sig);   % + 0 removes "-0.0"
end

function n = counter(kind)
% Running figure / table numbers.
persistent nf nt
switch kind
    case 'reset'
        nf = 0;
        nt = 0;
    case 'nextfig'
        nf = nf + 1;
    case 'nexttab'
        nt = nt + 1;
end
if contains(kind, 'tab')
    n = nt;
else
    n = nf;
end
end

function para(d, text, style)
import mlreportgen.dom.*
p = Paragraph(text);
p.Style = [{FontFamily('Arial'), FontSize('9.5pt'), Color('#1f2933'), LineSpacing(1.15), ...
    OuterMargin('0pt', '0pt', '0pt', '6pt')}, style];
append(d, p);
end

function heading(d, text)
import mlreportgen.dom.*
p = Paragraph(text);
p.Style = {FontFamily('Arial'), FontSize('13pt'), Bold(true), Color('#12171d'), KeepWithNext(true), ...
    OuterMargin('0pt', '0pt', '10pt', '5pt')};
append(d, p);
end

function subheading(d, text)
import mlreportgen.dom.*
p = Paragraph(text);
p.Style = {FontFamily('Arial'), FontSize('10.5pt'), Bold(true), Color('#1d5ea8'), KeepWithNext(true), ...
    OuterMargin('0pt', '0pt', '8pt', '4pt')};
append(d, p);
end

function bullets(d, items)
% items: N x 2 cell {bold lead, rest}
import mlreportgen.dom.*
ul = UnorderedList();
for k = 1:size(items, 1)
    p = Paragraph();
    p.Style = {FontFamily('Arial'), FontSize('9.5pt'), Color('#1f2933'), LineSpacing(1.12), ...
        OuterMargin('0pt', '0pt', '0pt', '3pt')};
    lead = Text(items{k, 1});
    lead.Style = {Bold(true)};
    append(p, lead);
    append(p, Text(items{k, 2}));
    li = ListItem();
    append(li, p);
    append(ul, li);
end
ul.Style = {OuterMargin('0pt', '0pt', '0pt', '6pt')};
append(d, ul);
end

function table(d, header, rows, note, widths, name)
import mlreportgen.dom.*
n = counter('nexttab');
cap = Paragraph();
lead = Text(sprintf('Table %d. ', n));
lead.Style = {Bold(true)};
append(cap, lead);
append(cap, Text(name));
cap.Style = {FontFamily('Arial'), FontSize('8.5pt'), Color('#47515c'), KeepWithNext(true), OuterMargin('0pt', '0pt', '6pt', '2pt')};
append(d, cap);
t = Table([header; rows]);
grp = TableColSpecGroup();
specs = TableColSpec.empty;
for k = 1:numel(widths)
    s = TableColSpec();
    s.Style = {Width(widths{k})};
    specs(k) = s;
end
grp.ColSpecs = specs;
t.ColSpecGroups = grp;
t.Style = {Width('100%'), Border('solid', '#9aa5b1', '0.5pt'), ColSep('solid', '#d3d9e0', '0.5pt'), ...
    RowSep('solid', '#d3d9e0', '0.5pt'), FontFamily('Arial'), FontSize('8pt'), Color('#1f2933'), ...
    OuterMargin('0pt', '0pt', '0pt', '2pt'), ResizeToFitContents(false)};
t.TableEntriesStyle = {InnerMargin('3.5pt', '3.5pt', '2pt', '2pt')};
hr = t.row(1);
hr.Style = {Bold(true), BackgroundColor('#e6eef8'), KeepWithNext(true)};
for r = 2:numel(t.Children)
    % keep the whole table and its note on one page
    tr = t.row(r);
    tr.Style = {KeepWithNext(true)};
end
append(d, t);
p = Paragraph(note);
p.Style = {FontFamily('Arial'), FontSize('7.5pt'), Italic(true), Color('#6b7480'), OuterMargin('0pt', '0pt', '0pt', '9pt')};
append(d, p);
end

function figure_(d, file, caption, maxH)
import mlreportgen.dom.*
n = counter('nextfig');
info = imfinfo(file);
w = 6.5;
h = w * info.Height / info.Width;
if h > maxH
    h = maxH;
    w = h * info.Width / info.Height;
end
img = Image(file);
img.Width = sprintf('%.2fin', w);
img.Height = sprintf('%.2fin', h);
p = Paragraph();
p.Style = {HAlign('center'), KeepWithNext(true), OuterMargin('0pt', '0pt', '6pt', '2pt')};
append(p, img);
append(d, p);
c = Paragraph();
lead = Text(sprintf('Figure %d. ', n));
lead.Style = {Bold(true)};
append(c, lead);
append(c, Text(caption));
c.Style = {FontFamily('Arial'), FontSize('8.5pt'), Color('#47515c'), OuterMargin('0pt', '0pt', '0pt', '10pt')};
append(d, c);
end

function pageBreak(d)
import mlreportgen.dom.*
append(d, PageBreak());
end
