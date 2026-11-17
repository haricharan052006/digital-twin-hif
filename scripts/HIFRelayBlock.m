classdef HIFRelayBlock < matlab.System
    %HIFRELAYBLOCK  In-model HIF relay for ieee13_hif_twin_system.slx.
    %
    % Input:   dI     [1 x 3] lateral-head digital-twin residual current
    %                 I_physical - I_twin (A), at the model base rate.
    % Outputs: trip   latched trip command (0 = healthy, 1 = tripped)
    %          class  latest window classification:
    %                 0 Normal | 1 Switching_Transient |
    %                 2 HIF_Phase_A | 3 HIF_Phase_B | 4 HIF_Phase_C
    %
    % Keeps a circular buffer of the last windowLen samples (2 cycles at
    % 20 kHz, from models/hif_relay_model.mat) and, once it is full,
    % re-classifies the window every EvalSteps samples (half a cycle) with
    % hif_window_features.m + the compact Random Forest trained by
    % train_classifiers.m - exactly the features and windows it was trained
    % on. The trip latches once at least ConfirmCount of the last
    % ConfirmWindow decisions are HIF (default 2 of 3, ~25-35 ms after a
    % typical arc ignites). A strict 3-in-a-row rule missed weak, sputtering
    % arcs whose HIF decisions came every other window.
    %
    % Outputs are computed from state only (no direct feedthrough), so the
    % closed loop trip -> breaker -> lateral current -> residual -> relay
    % has a one-step delay and no algebraic loop.
    %
    % Simulated with 'Interpreted execution' (the Random Forest is called
    % through the MATLAB interpreter, not code generation).
    %
    % The classifier comes from the bundle's 'kind' (journal comparison,
    % build_dl_relay_bundles.m); bundles without it are the RF relay:
    %   rf    hif_window_features -> z-score -> Random Forest (default)
    %   lgbm  hif_window_features -> LightGBM (lgbm_predict_flat.m)
    %   cnn   raw window -> end-to-end 1D-CNN (cnn_predict_window.m)
    % Window, evaluation cadence and the 2-of-3 latch are the same for all.
    %
    % UseBlockInput = true adds a second input 'block' (RelayInterlockBlock):
    % while it is high the relay keeps classifying (class output) but its
    % latch and vote history are cleared every step, so it can only trip on
    % fresh decisions once the block lifts. With block = 0 the relay behaves
    % exactly as with one input.

    properties (Nontunable)
        % Relay bundle written by train_classifiers.m (path relative to the
        % project's models/ folder, or absolute).
        ModelFile = 'hif_relay_model.mat';
        % Samples between classifications (167 = half a cycle at 20 kHz).
        EvalSteps = 167;
        % HIF decisions required within the last ConfirmWindow decisions.
        ConfirmCount = 2;
        % Number of most recent decisions the vote is taken over.
        ConfirmWindow = 3;
        % Classify with the forest flattened to plain arrays (rf_flatten /
        % rf_predict_flat: same trees, same labels as predict() on every
        % training window, ~0.5 ms instead of ~100 ms per decision).
        % false = call predict() on the compact ensemble directly.
        FastPredict = true;
        % Second input 'block' from the inter-relay interlock (see above).
        UseBlockInput (1, 1) logical = false;
    end

    properties (Access = private)
        Bundle
        Buffer
        WritePos = 0;
        Filled = 0;
        StepsSinceEval = 0;
        HifHistory = [];
        Tripped = 0;
        LastClass = 0;
    end

    methods (Access = protected)
        function setupImpl(obj)
            obj.Bundle = loadBundle(obj.ModelFile);
            if obj.FastPredict && strcmp(obj.Bundle.kind, 'rf')
                obj.Bundle.flat = rf_flatten(obj.Bundle.relayModel);
            end
            obj.Buffer = zeros(obj.Bundle.windowLen, 3);
            obj.HifHistory = false(1, obj.ConfirmWindow);
        end

        function resetImpl(obj)
            if ~isempty(obj.Buffer)
                obj.Buffer(:) = 0;
            end
            obj.WritePos = 0;
            obj.Filled = 0;
            obj.StepsSinceEval = 0;
            obj.HifHistory = false(1, obj.ConfirmWindow);
            obj.Tripped = 0;
            obj.LastClass = 0;
        end

        function [trip, cls] = outputImpl(obj, varargin)
            trip = obj.Tripped;
            cls = obj.LastClass;
        end

        function updateImpl(obj, dI, varargin)
            W = obj.Bundle.windowLen;
            obj.WritePos = mod(obj.WritePos, W) + 1;
            obj.Buffer(obj.WritePos, :) = double(dI(:)');
            obj.Filled = min(obj.Filled + 1, W);
            obj.StepsSinceEval = obj.StepsSinceEval + 1;
            blocked = obj.UseBlockInput && varargin{1} > 0.5;
            if blocked
                obj.Tripped = 0;
                obj.HifHistory(:) = false;
            end
            if obj.Tripped || obj.Filled < W || obj.StepsSinceEval < obj.EvalSteps
                return;
            end
            obj.StepsSinceEval = 0;

            % Oldest-to-newest window, then classify.
            win = obj.Buffer([obj.WritePos + 1:W, 1:obj.WritePos], :);
            switch obj.Bundle.kind
                case 'rf'
                    z = (hif_window_features(win) - obj.Bundle.scaler.mu) ./ obj.Bundle.scaler.sigma;
                    if obj.FastPredict
                        label = rf_predict_flat(obj.Bundle.flat, z);
                    else
                        label = string(predict(obj.Bundle.relayModel, z));
                    end
                case 'lgbm'
                    label = lgbm_predict_flat(obj.Bundle.lgbm, hif_window_features(win));
                case 'cnn'
                    label = cnn_predict_window(obj.Bundle.cnn, win);
            end
            obj.LastClass = find(obj.Bundle.classNames == label, 1) - 1;

            if blocked
                return;
            end
            obj.HifHistory = [obj.HifHistory(2:end), startsWith(label, "HIF")];
            if nnz(obj.HifHistory) >= obj.ConfirmCount
                obj.Tripped = 1;
            end
        end

        function varargout = isInputDirectFeedthroughImpl(~, varargin)
            % one false per input: outputs come from state only
            varargout = repmat({false}, 1, max(nargout, 1));
        end

        function num = getNumInputsImpl(obj)
            num = 1 + obj.UseBlockInput;
        end

        function num = getNumOutputsImpl(~)
            num = 2;
        end

        function [s1, s2] = getOutputSizeImpl(~)
            s1 = [1 1];
            s2 = [1 1];
        end

        function [d1, d2] = getOutputDataTypeImpl(~)
            d1 = 'double';
            d2 = 'double';
        end

        function [c1, c2] = isOutputComplexImpl(~)
            c1 = false;
            c2 = false;
        end

        function [f1, f2] = isOutputFixedSizeImpl(~)
            f1 = true;
            f2 = true;
        end

        function [n1, n2] = getOutputNamesImpl(~)
            n1 = 'trip';
            n2 = 'class';
        end

        function icon = getIconImpl(~)
            icon = sprintf('HIF Relay\n(db4 DWT + RF)');
        end
    end
end

%% ======================================================================
function b = loadBundle(modelFile)
if isfile(modelFile)
    f = modelFile;
else
    projectRoot = fileparts(fileparts(mfilename('fullpath')));
    f = fullfile(projectRoot, 'models', modelFile);
end
if ~isfile(f)
    error('HIFRelayBlock:ModelMissing', ...
        '%s not found. Run scripts/train_classifiers.m first.', f);
end
if ismember('kind', who('-file', f))
    b = load(f, 'kind', 'classNames', 'windowLen');
    if ~ismember(b.kind, {'lgbm', 'cnn'})
        error('HIFRelayBlock:UnknownKind', 'Unknown classifier kind "%s" in %s.', b.kind, f);
    end
    m = load(f, b.kind);
    b.(b.kind) = m.(b.kind);
else
    b = load(f, 'relayModel', 'scaler', 'classNames', 'windowLen');
    b.kind = 'rf';
end
b.classNames = string(b.classNames);
end
