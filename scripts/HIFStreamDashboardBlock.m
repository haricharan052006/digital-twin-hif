classdef HIFStreamDashboardBlock < matlab.System
    %HIFSTREAMDASHBOARDBLOCK  Real-time dashboard visualization tap for
    % models/ieee13_physical.slx.
    %
    % A pure visualization SINK (no output ports, like a Scope): branched
    % off the EXISTING VI_650 current measurement by
    % add_stream_dashboard_block.m (does not consume, replace, or alter
    % that signal - zero feedback into the electrical network), plus an
    % explicit simulation-time input fed by a Clock block.
    %
    % DELIBERATE DESIGN CHOICE - manual counter decimation, not
    % getSampleTimeImpl/createSampleTime: a MATLAB System block CAN be
    % given its own slower discrete sample time so Simulink itself only
    % calls stepImpl at that rate, but that mechanism's exact API has
    % enough version-to-version subtlety that, given how many other
    % subtle Simulink-parameter mismatches turned up over the course of
    % this project (breaker SwitchTimes vs SwitchingTimes, block-name
    % underscores, etc.), the safer and equally effective choice is: run
    % at the model's BASE rate (every call), but do essentially nothing
    % (one integer increment-and-compare) on all but every 100th call.
    % The net visual/performance result is identical - a dashboard update
    % roughly every 5 ms (100 x 50 us) - with no dependency on a sample-
    % time API this file cannot verify against a live MATLAB session.
    %
    % Calls stream_live_hif_dashboard.m, which drives a genuinely
    % real-time (during-simulation) amplitude-threshold alarm - see that
    % file's header for why the trained SVM itself cannot meaningfully
    % run at this cadence, and how its accurate confirmation still
    % happens separately, at run end, via update_live_hif_dashboard.m's
    % existing StopFcn.

    properties (Nontunable)
        % Number of base-rate steps between dashboard updates. At the
        % project's standard Ts = 50e-6 s, 100 steps = 5 ms.
        DecimationSteps = 100;
    end

    properties (Access = private)
        StepCounter = 0;
    end

    methods (Access = protected)
        function setupImpl(obj)
            obj.StepCounter = 0;
            stream_live_hif_dashboard('reset');
        end

        function stepImpl(obj, I650, t)
            obj.StepCounter = obj.StepCounter + 1;
            if obj.StepCounter >= obj.DecimationSteps
                obj.StepCounter = 0;
                stream_live_hif_dashboard('tick', t, I650);
            end
        end

        function num = getNumInputsImpl(~)
            num = 2;   % 1: I_650 (3-phase current), 2: simulation time (from a Clock block)
        end

        function num = getNumOutputsImpl(~)
            num = 0;
        end

        function icon = getIconImpl(~)
            icon = sprintf('HIF Live\nDashboard');
        end
    end
end
