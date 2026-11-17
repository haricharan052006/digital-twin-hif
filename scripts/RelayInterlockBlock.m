classdef RelayInterlockBlock < matlab.System
    %RELAYINTERLOCKBLOCK  Inter-relay blocking interlock between the two
    % lateral HIF relays of ieee13_hif_twin_system.slx (journal study, stage 4).
    %
    % Inputs:  trip633, trip675   raw latched trips of HIF_Relay_633 / _675
    %          dI633, dI675       [1 x 3] lateral-head residuals (A)
    % Outputs: tripOut633/675     trips passed to the breaker commands
    %          block633/675       block inputs of the two relays
    %
    % Enable = 0 (default): trips pass straight through, blocks stay 0 -
    % the model behaves exactly as without the interlock.
    %
    % Enable = 1 - a blocking scheme for selectivity between laterals:
    %   - the first relay to trip is granted: its trip goes to its breaker, and
    %     the neighbouring relay is blocked for BlockSteps samples (breaker
    %     operating time + a margin that lets its two-cycle window clear of
    %     fault-disturbed samples). A blocked relay is reset every step
    %     (HIFRelayBlock UseBlockInput), so after the block it can only trip
    %     on fresh evidence - a second, genuine fault on its own lateral.
    %   - same-step tie (both relays latch on the same 8.35 ms decision tick):
    %     the lateral whose residual carries more ZERO-SEQUENCE energy
    %     (sum of the three phase residuals, squared) over the last
    %     EnergyWindow samples is granted, the other blocked. An HIF is a
    %     ground fault, so its return current appears as 3*I0 on the faulted
    %     lateral, while the neighbouring lateral's response to the voltage
    %     sag is largely balanced. TieBreak = 'total' uses the all-phase
    %     residual energy instead; in the closed-loop study that rule picked
    %     the healthy lateral in 6 of 12 ties (a weak arc carries less
    %     current than the neighbour's sag response), the zero-sequence rule
    %     in 0 of 12 (compare_interlock.m).
    % Direct feedthrough on every input; the relays have none, so the loop
    % relay -> interlock -> relay block input is free of algebraic loops.

    properties (Nontunable)
        % Interlock on (1) or pass-through (0). Numeric, not logical, so the
        % block can take a workspace variable (InterlockEnable).
        Enable = 0;
        % Samples the neighbouring relay stays blocked after a grant.
        BlockSteps = 1000;
        % Residual-energy window for the tie-break (667 = two cycles at 20 kHz).
        EnergyWindow = 667;
        % Tie-break quantity: 'zero-sequence' or 'total' residual energy.
        TieBreak = 'zero-sequence';
    end

    properties (Constant, Hidden)
        TieBreakSet = matlab.system.StringSet({'zero-sequence', 'total'});
    end

    properties (Access = private)
        Energy          % [EnergyWindow x 2] squared residual per sample and lateral
        Pos = 0;
        BlockLeft = [0 0];
        Granted = [false false];
    end

    methods (Access = protected)
        function setupImpl(obj)
            obj.Energy = zeros(obj.EnergyWindow, 2);
        end

        function resetImpl(obj)
            if ~isempty(obj.Energy)
                obj.Energy(:) = 0;
            end
            obj.Pos = 0;
            obj.BlockLeft = [0 0];
            obj.Granted = [false false];
        end

        function [out633, out675, blk633, blk675] = stepImpl(obj, trip633, trip675, dI633, dI675)
            trips = [trip633, trip675] > 0.5;
            if obj.Enable <= 0
                out633 = double(trips(1));
                out675 = double(trips(2));
                blk633 = 0;
                blk675 = 0;
                return;
            end
            obj.Pos = mod(obj.Pos, obj.EnergyWindow) + 1;
            if strcmp(obj.TieBreak, 'zero-sequence')
                obj.Energy(obj.Pos, :) = [sum(double(dI633))^2, sum(double(dI675))^2];
            else
                obj.Energy(obj.Pos, :) = [sum(double(dI633).^2), sum(double(dI675).^2)];
            end
            obj.BlockLeft = max(obj.BlockLeft - 1, 0);

            eff = trips & obj.BlockLeft == 0;
            fresh = eff & ~obj.Granted;
            if all(fresh) && ~any(obj.Granted)
                % Same-step tie: grant the lateral with the larger (zero-sequence) residual energy.
                [~, win] = max(sum(obj.Energy, 1));
                fresh(3 - win) = false;
                eff(3 - win) = false;
                obj.BlockLeft(3 - win) = obj.BlockSteps;
            end
            for i = find(fresh)
                obj.Granted(i) = true;
                if ~obj.Granted(3 - i)
                    obj.BlockLeft(3 - i) = obj.BlockSteps;
                    eff(3 - i) = false;
                end
            end
            out633 = double(eff(1));
            out675 = double(eff(2));
            blk633 = double(obj.BlockLeft(1) > 0);
            blk675 = double(obj.BlockLeft(2) > 0);
        end

        function num = getNumInputsImpl(~)
            num = 4;
        end

        function num = getNumOutputsImpl(~)
            num = 4;
        end

        function [s1, s2, s3, s4] = getOutputSizeImpl(~)
            s1 = [1 1];
            s2 = [1 1];
            s3 = [1 1];
            s4 = [1 1];
        end

        function [d1, d2, d3, d4] = getOutputDataTypeImpl(~)
            d1 = 'double';
            d2 = 'double';
            d3 = 'double';
            d4 = 'double';
        end

        function [c1, c2, c3, c4] = isOutputComplexImpl(~)
            c1 = false;
            c2 = false;
            c3 = false;
            c4 = false;
        end

        function [f1, f2, f3, f4] = isOutputFixedSizeImpl(~)
            f1 = true;
            f2 = true;
            f3 = true;
            f4 = true;
        end

        function [n1, n2, n3, n4] = getInputNamesImpl(~)
            n1 = 'trip633';
            n2 = 'trip675';
            n3 = 'dI633';
            n4 = 'dI675';
        end

        function [n1, n2, n3, n4] = getOutputNamesImpl(~)
            n1 = 'tripOut633';
            n2 = 'tripOut675';
            n3 = 'block633';
            n4 = 'block675';
        end

        function icon = getIconImpl(~)
            icon = sprintf('Relay Interlock\n(block neighbour)');
        end
    end
end
