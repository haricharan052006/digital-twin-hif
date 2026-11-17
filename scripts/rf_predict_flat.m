function [labels, scores] = rf_predict_flat(F, X)
%RF_PREDICT_FLAT  Predict with a forest flattened by rf_flatten.m.
%   [labels, scores] = rf_predict_flat(F, X), X [N x P] (already scaled the
%   way the model was trained). labels is an N x 1 string array, scores the
%   N x K weighted-average leaf class probabilities.

N = size(X, 1);
K = numel(F.classNames);
scores = zeros(N, K);
for t = 1:numel(F.cutVar)
    cutVar = F.cutVar{t};
    cutPoint = F.cutPoint{t};
    children = F.children{t};
    leafProb = F.leafProb{t};
    for n = 1:N
        node = 1;
        while children(node, 1) > 0
            if X(n, cutVar(node)) < cutPoint(node)
                node = children(node, 1);
            else
                node = children(node, 2);
            end
        end
        scores(n, :) = scores(n, :) + F.weights(t) * leafProb(node, :);
    end
end
[~, idx] = max(scores, [], 2);
labels = F.classNames(idx);
end
