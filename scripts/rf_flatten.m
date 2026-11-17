function F = rf_flatten(mdl)
%RF_FLATTEN  Flatten a compact bagged classification ensemble into plain
% arrays for fast single-window prediction (see rf_predict_flat.m).
%
% predict() on the 100-tree CompactClassificationEnsemble costs ~100 ms per
% call from the MATLAB System relay (argument validation and per-tree
% object dispatch, not the tree arithmetic), which made the relay ~70% of
% the closed-loop simulation time. The flattened form walks the same trees
% with the same rule (x < CutPoint -> left child), averages the same leaf
% class probabilities with the same learner weights, and takes the same
% arg-max, so it returns the same labels as predict() - verified on every
% training window when the relay model is built (train_classifiers.m) and
% re-checkable with rf_predict_flat(F, X) vs predict(mdl, X).

T = numel(mdl.Trained);
F.classNames = string(mdl.ClassNames);
F.weights = mdl.TrainedWeights(:) / sum(mdl.TrainedWeights);
F.cutVar = cell(T, 1);
F.cutPoint = cell(T, 1);
F.children = cell(T, 1);
F.leafProb = cell(T, 1);
for t = 1:T
    tree = mdl.Trained{t};
    if ~isempty(tree.CategoricalPredictors)
        error('rf_flatten:Categorical', 'Categorical splits are not supported.');
    end
    F.cutVar{t} = tree.CutPredictorIndex;
    F.cutPoint{t} = tree.CutPoint;
    F.children{t} = tree.Children;
    F.leafProb{t} = tree.ClassProbability;
end
end
