%% train_rf_noise_aug.m
% Journal comparison study: the relay Random Forest retrained on the
% noise-augmented training set (clean training windows + the noisy copies of
% export_noise_augmented_train.m), with the deployed recipe of
% train_classifiers.m: z-score fit on the training rows, 100 bagged trees,
% Reproducible template, rng(42). Test runs are never used for training.
%
% Outputs:
%   models/hif_relay_model_noiseaug.mat     relay bundle (same format as
%                                           hif_relay_model.mat, usable by
%                                           HIFRelayBlock via ModelFile)
%   results/dl/pred_rf_aug_test.csv         clean held-out test windows
%   results/dl/noise/pred_rf_aug_sigma<i>.csv   noise sweep (export_noisy_test.m)
%
% Requires: Statistics and Machine Learning Toolbox.

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);
dlDir = fullfile(projectRoot, 'data', 'dl');
resDir = fullfile(projectRoot, 'results', 'dl');

F = load(fullfile(projectRoot, 'data', 'features.mat'), 'X', 'y', 'featureNames');
R = load(fullfile(projectRoot, 'models', 'hif_relay_model.mat'), 'classNames', 'windowLen', 'hopLen', 'Ts');
Wtab = readtable(fullfile(dlDir, 'windows.csv'), 'TextType', 'string');
A = readtable(fullfile(dlDir, 'aug', 'windows_aug.csv'));
aug = jsondecode(fileread(fullfile(dlDir, 'aug', 'aug.json')));
fid = fopen(fullfile(dlDir, 'aug', 'features_f64.bin'), 'r');
Xaug = reshape(fread(fid, inf, 'double'), aug.n_features, [])';
fclose(fid);
assert(size(Xaug, 1) == height(A), 'Augmented features and index disagree.');

train = Wtab.split == "train";
Xtr = [F.X(train, :); Xaug];
ytr = [F.y(train); F.y(A.source_row)];
classNames = categories(F.y);
fprintf('Training rows: %d clean + %d noisy = %d\n', nnz(train), height(A), numel(ytr));

mu = mean(Xtr, 1);
sd = std(Xtr, 0, 1);
sd(sd == 0) = 1;
rng(42);
tic;
mdl = fitcensemble((Xtr - mu) ./ sd, ytr, 'Method', 'Bag', 'NumLearningCycles', 100, ...
    'Learners', templateTree('Reproducible', true), 'ClassNames', classNames);
fprintf('Random Forest trained in %.0f s\n', toc);

relayModel = compact(mdl);
scaler = struct('mu', mu, 'sigma', sd, 'featureNames', {F.featureNames});
featureNames = F.featureNames;
windowLen = R.windowLen;
hopLen = R.hopLen;
Ts = R.Ts;
save(fullfile(projectRoot, 'models', 'hif_relay_model_noiseaug.mat'), 'relayModel', 'scaler', ...
    'classNames', 'featureNames', 'windowLen', 'hopLen', 'Ts');

pCols = compose('p%d', 0:4);
test = find(Wtab.split == "test");
[lab, score] = predict(relayModel, (F.X(test, :) - mu) ./ sd);
[~, c] = ismember(lab, classNames);
writetable([table(Wtab.row(test), c - 1, 'VariableNames', {'row', 'pred'}), ...
    array2table(score, 'VariableNames', pCols)], fullfile(resDir, 'pred_rf_aug_test.csv'));

noise = jsondecode(fileread(fullfile(dlDir, 'noise', 'noise.json')));
for i = 1:numel(noise.sigmas)
    fid = fopen(fullfile(dlDir, 'noise', sprintf('features_sigma%d.bin', i)), 'r');
    Xn = reshape(fread(fid, inf, 'double'), noise.n_features, [])';
    fclose(fid);
    [lab, score] = predict(relayModel, (Xn - mu) ./ sd);
    [~, c] = ismember(lab, classNames);
    writetable([table(noise.rows(:), c - 1, 'VariableNames', {'row', 'pred'}), ...
        array2table(score, 'VariableNames', pCols)], fullfile(resDir, 'noise', sprintf('pred_rf_aug_sigma%d.csv', i)));
end
fprintf('Saved models/hif_relay_model_noiseaug.mat, results/dl/pred_rf_aug_test.csv, results/dl/noise/pred_rf_aug_sigma*.csv\n');
