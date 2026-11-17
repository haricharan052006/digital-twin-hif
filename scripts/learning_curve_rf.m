%% learning_curve_rf.m
% Learning curve of the relay Random Forest on the same nested training-run
% subsets as dl/learning_curve.py (results/dl/learning_curve/subsets.csv):
% 25 / 50 / 75 / 100 % of the 720 training runs, repeats r = 0, 1, 2. The
% deployed recipe (z-score on the subset, 100 bagged trees, Reproducible
% template) with rng(42 + r). The 100 % point of repeat 0 uses the deployed
% recipe and seed but is not bit-identical to the deployed relay
% (train_classifiers.m draws its split from the same stream before fitting;
% 24 of 5161 test labels differ). Predicts the 180 held-out test runs.
%
% Output: results/dl/learning_curve/pred_rf_f{25,50,75,100}_r{0,1,2}.csv
%
% Requires: Statistics and Machine Learning Toolbox.

scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);
outDir = fullfile(projectRoot, 'results', 'dl', 'learning_curve');

F = load(fullfile(projectRoot, 'data', 'features.mat'), 'X', 'y');
Wtab = readtable(fullfile(projectRoot, 'data', 'dl', 'windows.csv'), 'TextType', 'string');
Sub = readtable(fullfile(outDir, 'subsets.csv'));
classNames = categories(F.y);
train = Wtab.split == "train";
test = find(Wtab.split == "test");
pCols = compose('p%d', 0:4);

for f = [25 50 75 100]
    for r = 0:2
        outFile = fullfile(outDir, sprintf('pred_rf_f%d_r%d.csv', f, r));
        if isfile(outFile)
            continue;
        end
        if f == 100
            runs = Sub.run(Sub.repeat == r);
        else
            runs = Sub.run(Sub.repeat == r & Sub.(sprintf('in%d', f)) == 1);
        end
        m = train & ismember(Wtab.run, runs);
        mu = mean(F.X(m, :), 1);
        sd = std(F.X(m, :), 0, 1);
        sd(sd == 0) = 1;
        rng(42 + r);
        tic;
        mdl = fitcensemble((F.X(m, :) - mu) ./ sd, F.y(m), 'Method', 'Bag', 'NumLearningCycles', 100, ...
            'Learners', templateTree('Reproducible', true), 'ClassNames', classNames);
        [lab, score] = predict(mdl, (F.X(test, :) - mu) ./ sd);
        [~, c] = ismember(lab, classNames);
        writetable([table(Wtab.row(test), c - 1, 'VariableNames', {'row', 'pred'}), ...
            array2table(score, 'VariableNames', pCols)], outFile);
        fprintf('RF %3d %% repeat %d: %d runs, %d windows, %.0f s\n', f, r, numel(runs), nnz(m), toc);
    end
end
