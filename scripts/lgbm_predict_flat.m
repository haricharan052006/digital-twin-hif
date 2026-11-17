function [labels, probs] = lgbm_predict_flat(G, X)
%LGBM_PREDICT_FLAT  Predict with a LightGBM model flattened by
% dl/export_relay_bundles.py (see build_dl_relay_bundles.m).
%   [labels, probs] = lgbm_predict_flat(G, X), X [N x 87] raw (unscaled) db4
%   features. labels is an N x 1 string array, probs the N x K softmax of the
%   summed leaf values per class - LightGBM's own multiclass output.
%
% All trees are walked together, one tree level per iteration: node arrays
% are global, a child >= 1 is an internal node, a child <= 0 is leaf -child + 1
% (rule: x(feature) <= threshold -> left).

N = size(X, 1);
probs = zeros(N, G.numClass);
for n = 1:N
    x = X(n, :)';    % column, like the node arrays
    cur = G.root;
    active = cur >= 1;
    while any(active)
        node = cur(active);
        goLeft = x(G.feature(node)) <= G.threshold(node);
        next = G.right(node);
        next(goLeft) = G.left(node(goLeft));
        cur(active) = next;
        active = cur >= 1;
    end
    leaf = 1 - cur;
    raw = accumarray(G.leafClass(leaf), G.leafValue(leaf), [G.numClass 1])';
    e = exp(raw - max(raw));
    probs(n, :) = e / sum(e);
end
[~, idx] = max(probs, [], 2);
labels = G.classNames(idx);
end
