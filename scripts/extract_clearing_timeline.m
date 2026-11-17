function tl = extract_clearing_timeline(r)
%EXTRACT_CLEARING_TIMELINE  Protection timeline of one closed-loop run of
% run_twin_isolation_case.m (journal comparison, stage 4).
%
%   tl = extract_clearing_timeline(r)
%
% Instants (s, NaN = did not happen within the run), for an HIF run on the
% faulted lateral L:
%   t0       fault inception: the arc branch's fault breaker closes (r.tEvent)
%   tArc     first arc current |I_arc| > 1 mA (arc strikes)
%   t1       first relay decision classifying HIF on lateral L at or after t0
%   t2       trip asserted: relay L's 2-of-3 latch (Trip_L)
%   t3       breaker contacts part: delayed close command falls to 0
%            (t2 + breaker operating time)
%   t4       arc extinguished: last sample with |I_arc| > 1 mA (NaN if the
%            arc is still conducting in the last cycle of the run)
%   t4all    all three lateral phases interrupted: last sample with any
%            |I_L phase| > 0.05 A
%   t5       isolation confirmed: end of the first full cycle after t3 in
%            which the lateral current AND the twin residual stay below
%            0.05 A on all phases
% Durations (ms): detect t1-t0, confirm t2-t1, mechanical t3-t2,
% extinction t4-t3, clearing t4-t0 (fault-clearing time), interruption
% t4all-t0, isolation t5-t0. Flags: missed (no trip on L), sympathetic
% (the other lateral's breaker got a trip), rawSympathetic (the other
% lateral's relay latched, whether or not the interlock let it through),
% preInception (L tripped before t0). Trip times are the trips that reached
% the breaker commands (r.tripOut_*, after the interlock).
% For a non-HIF run only the trip times / false-trip flags are filled.

ISO_A = 0.05;      % isolation threshold (A), as verify_twin_isolation.m
ARC_A = 1e-3;      % arc conducting (A)
t = r.time;
dt = median(diff(t));
cycleN = round((1 / 60) / dt);
lats = {'633', '675'};
tripT = [firstTime(t, r.tripOut_633 > 0.5), firstTime(t, r.tripOut_675 > 0.5)];
rawT = [firstTime(t, r.trip_633 > 0.5), firstTime(t, r.trip_675 > 0.5)];

tl = struct('scenario', string(r.scenario), 'bus', string(r.bus), 'phase', string(r.phase), ...
    'delayCycles', r.breakerDelayCycles, 'interlock', r.interlock, 't0', r.tEvent, 'tArc', NaN, ...
    't1', NaN, 't2', NaN, 't3', NaN, 't4', NaN, 't4all', NaN, 't5', NaN, 'tripTime633', tripT(1), ...
    'tripTime675', tripT(2), 'tripped', string(r.tripped), 'missed', false, 'sympathetic', false, ...
    'rawSympathetic', false, 'preInception', false, 'arcPeakA', NaN);
if ~strcmp(r.scenario, 'hif')
    return;
end
L = find(strcmp(lats, r.bus));
O = 3 - L;
t0 = r.tEvent;
after = t >= t0 - dt / 2;
tl.arcPeakA = max(abs(r.I_arc));
tl.tArc = firstTime(t, after & abs(r.I_arc) > ARC_A);
tl.t1 = firstTime(t, after & r.(['class_' lats{L}]) >= 2);
tl.t2 = tripT(L);
tl.t3 = firstTime(t, r.(['closeCmd_' lats{L}]) < 0.5);
tl.missed = isnan(tl.t2);
tl.sympathetic = ~isnan(tripT(O));
tl.rawSympathetic = ~isnan(rawT(O));
tl.preInception = tl.t2 < t0;
if isnan(tl.t3)
    return;
end
lastCycle = t > t(end) - 1 / 60;
if ~any(abs(r.I_arc(lastCycle)) > ARC_A)
    k = find(abs(r.I_arc) > ARC_A, 1, 'last');
    if ~isempty(k)
        tl.t4 = t(k);
    end
end
IL = r.(['I_' lats{L} '_physical']);
dIL = r.(['dI_' lats{L}]);
if ~any(abs(IL(lastCycle, :)) > ISO_A, 'all')
    k = find(any(abs(IL) > ISO_A, 2), 1, 'last');
    tl.t4all = t(k);
end
quiet = all(abs(IL) < ISO_A, 2) & all(abs(dIL) < ISO_A, 2);
run = movsum(double(quiet), [cycleN - 1, 0]) >= cycleN;      % trailing full cycle quiet
tl.t5 = firstTime(t, run & t >= tl.t3);
end

%% ======================================================================
function v = firstTime(t, mask)
k = find(mask, 1);
if isempty(k)
    v = NaN;
else
    v = t(k);
end
end
