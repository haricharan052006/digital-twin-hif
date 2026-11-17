%% predict_svm_mlp.m
% Journal comparison study: adds the SVM (ECOC, Gaussian kernel) and the
% feedforward MLP of train_classifiers.m as extra baselines. Both were trained
% on the same 87 db4 features and the same run-grouped split as the deployed
% RF (models/trained_classifiers.mat), clean signals only. Writes their
% predictions on the held-out test windows and on the noise sweep of
% export_noisy_test.m in the format of the other models.
%
% Class scores p0..p4: posterior of the MLP; for the SVM the softmax of the
% ECOC negative loss (a ranking score for ROC curves, not a calibrated
% probability).
%
% Outputs: results/dl/pred_{svm,mlp}_test.csv,
%          results/dl/noise/pred_{svm,mlp}_sigma<i>.csv
% Requires: Statistics and Machine Learning Toolbox.

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);
dlDir = fullfile(projectRoot, 'data', 'dl');
resDir = fullfile(projectRoot, 'results', 'dl');

T = load(fullfile(projectRoot, 'models', 'trained_classifiers.mat'), 'mdlSVM', 'mdlNN', 'scaler', 'results', 'classNames');
F = load(fullfile(projectRoot, 'data', 'features.mat'), 'X');
Wtab = readtable(fullfile(dlDir, 'windows.csv'), 'TextType', 'string');
noise = jsondecode(fileread(fullfile(dlDir, 'noise', 'noise.json')));
test = find(Wtab.split == "test");
classNames = T.classNames;
mu = T.scaler.mu;
sd = T.scaler.sigma;

writePred(fullfile(resDir, 'pred_svm_test.csv'), T.mdlSVM, 'svm', (F.X(test, :) - mu) ./ sd, Wtab.row(test), classNames);
writePred(fullfile(resDir, 'pred_mlp_test.csv'), T.mdlNN, 'mlp', (F.X(test, :) - mu) ./ sd, Wtab.row(test), classNames);

% consistency with the metrics stored by train_classifiers.m
for pair = {'svm', 'SVM'; 'mlp', 'NeuralNetwork'}'
    P = readtable(fullfile(resDir, sprintf('pred_%s_test.csv', pair{1})));
    m = relay_window_metrics(Wtab(P.row, :), P.pred);
    stored = T.results.(pair{2}).Accuracy;
    fprintf('%s test accuracy %.4f (stored %.4f), macro F1 %.4f, fault detection %.4f\n', pair{1}, m.Accuracy, stored, m.MacroF1, m.Dependability);
    assert(abs(m.Accuracy - stored) < 1e-12, 'Predictions do not reproduce the stored %s accuracy.', pair{2});
end

for i = 1:numel(noise.sigmas)
    fid = fopen(fullfile(dlDir, 'noise', sprintf('features_sigma%d.bin', i)), 'r');
    Xn = reshape(fread(fid, inf, 'double'), noise.n_features, [])';
    fclose(fid);
    Z = (Xn - mu) ./ sd;
    writePred(fullfile(resDir, 'noise', sprintf('pred_svm_sigma%d.csv', i)), T.mdlSVM, 'svm', Z, noise.rows(:), classNames);
    writePred(fullfile(resDir, 'noise', sprintf('pred_mlp_sigma%d.csv', i)), T.mdlNN, 'mlp', Z, noise.rows(:), classNames);
    fprintf('sigma %g A done\n', noise.sigmas(i));
end

%% ======================================================================
function writePred(file, mdl, kind, Z, rows, classNames)
[lab, s] = predict(mdl, Z);
if strcmp(kind, 'svm')
    e = exp(s - max(s, [], 2));   % s = ECOC negative loss
    s = e ./ sum(e, 2);
end
[~, c] = ismember(lab, classNames);
writetable([table(rows(:), c - 1, 'VariableNames', {'row', 'pred'}), ...
    array2table(s, 'VariableNames', compose('p%d', 0:4))], file);
end
