function [label, probs] = cnn_predict_window(C, win)
%CNN_PREDICT_WINDOW  Forward pass of the end-to-end 1D-CNN relay classifier
% (dl/hif_cnn.py, exported by dl/export_relay_bundles.py, bundled by
% build_dl_relay_bundles.m) on one raw residual window.
%   [label, probs] = cnn_predict_window(C, win), win [W x 3] lateral residual
%   (A), oldest sample first. label is a string, probs 1 x K softmax.
%
% Same arithmetic as PyTorch in eval mode: input scaling, then per block
% zero-padded Conv1d (no bias, im2col) -> BatchNorm with running statistics
% -> ReLU; global mean and max pooling, linear head, softmax.

x = double(win)';                         % [3 x W]
if strcmp(C.scaling.kind, 'slog')
    x = sign(x) .* log1p(abs(x) / C.scaling.x0);
else
    x = x / C.scaling.ref;
end
for b = 1:numel(C.blocks)
    B = C.blocks(b);
    [cout, cin, K] = size(B.weight);
    L = size(x, 2);
    xp = [zeros(cin, B.padding), x, zeros(cin, B.padding)];
    Lout = floor((L + 2 * B.padding - B.dilation * (K - 1) - 1) / B.stride) + 1;
    cols = zeros(cin, K, Lout);
    base = (0:Lout - 1) * B.stride + 1;
    for k = 1:K
        cols(:, k, :) = reshape(xp(:, base + (k - 1) * B.dilation), cin, 1, Lout);
    end
    z = reshape(B.weight, cout, cin * K) * reshape(cols, cin * K, Lout);
    z = (z - B.mean) ./ sqrt(B.var + B.eps) .* B.gamma + B.beta;
    x = max(z, 0);
end
logits = C.headWeight * [mean(x, 2); max(x, [], 2)] + C.headBias;
e = exp(logits - max(logits));
probs = (e / sum(e))';
[~, idx] = max(probs);
label = C.classNames(idx);
end
