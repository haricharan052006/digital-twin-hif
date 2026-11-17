function layout_twin_system(sysName)
%LAYOUT_TWIN_SYSTEM  Canvas layout for the Physical_Feeder and Digital_Twin
% subsystems of ieee13_hif_twin_system.slx (model must be loaded; the
% caller saves it).
%
% Visual only: every block keeps its size, orientation, ports and
% connections - only its Position is translated - and the connection lines
% are then re-routed so their drawn path follows the moved blocks (line
% geometry only; no line is added, deleted or reconnected).
%
% Blocks are grouped by bus on a 4 x 3 grid of 650 x 490 px cells, a
% ~2600 x 1470 (16:9) canvas laid out like the IEEE 13-node one-line
% diagram, so "Fit to View" frames the whole feeder legibly:
%
%            col 1               col 2              col 3                col 4
%   row 1    source / 650        lateral 633 head   633 HIF branches     XFM 633-634, 634 loads
%   row 2    645 / 646           671 hub            692 -> lateral 675   675 loads, cap bank
%   row 3    684 / 611 / 652 (cols 1-2)             680 terminations     675 HIF branches
%
% Before this, extend_fault_injection.m's slot placement stacked the 18
% fault-branch blocks in a diagonal staircase ~5000 px tall. Names absent
% from a subsystem (the twin has no fault branches or switching decoys)
% are skipped.

% 650 x 490 cells -> ~2600 x 1470 canvas. The height is set by the fixed
% (immovable) line junctions, which span y = 60-1481 (see redrawLines).
CELL_W = 650;
CELL_H = 490;
DX = 120;             % default column pitch inside a cell
DY = 110;             % row pitch inside a cell
MARGIN = [60 60];     % first block centre offset inside a cell

% cell {col, row, column pitch, rows-of-block-names}; '' leaves a gap
cells = {
    1, 1, 150, {{'I_650', 'Scope_I_650', 'ToWs_I_650'}, ...
                {'Src_650', 'VI_650', 'Line_650_632'}}
    2, 1, DX,  {{'Close_633', '', 'I_633L', 'VI_633L_Term'}, ...
                {'Brk_632_633', 'VI_633L', 'Line_632_633'}}
    3, 1, 160, {{'FaultBreaker_633A', 'FaultBreaker_633B', 'FaultBreaker_633C'}, ...
                {'Emanuel_Arc_Fault_633A', 'Emanuel_Arc_Fault_633B', 'Emanuel_Arc_Fault_633C'}, ...
                {'FaultGnd_633A', 'FaultGnd_633B', 'FaultGnd_633C'}}
    4, 1, DX,  {{'XFM_633_634'}, ...
                {'L634A', 'L634B', 'L634C'}, ...
                {'L634A_Gnd', 'L634B_Gnd', 'L634C_Gnd'}}
    1, 2, 150, {{'Line_632_645', 'Line_645_646'}, ...
                {'L645B', 'L646BC', 'Open646A'}, ...
                {'L645B_Gnd', '', 'Open646A_Gnd'}}
    2, 2, DX,  {{'Line_632_671', 'L671AB', 'L671BC', 'L671CA'}, ...
                {'LoadStepBrk_671', 'LoadStepA_671', 'LoadStepB_671', 'LoadStepC_671'}, ...
                {'', 'LoadStepA_671_Gnd', 'LoadStepB_671_Gnd', 'LoadStepC_671_Gnd'}}
    3, 2, 110, {{'', '', 'Close_675', 'I_675L', 'VI_675L_Term'}, ...
                {'Tie_671_692', 'L692CA', 'Brk_692_675', 'VI_675L', 'Line_692_675'}}
    4, 2, DX,  {{'L675A', 'L675B', 'L675C', 'CapBrk_675'}, ...
                {'L675A_Gnd', 'L675B_Gnd', 'L675C_Gnd'}, ...
                {'Cap675A', 'Cap675B', 'Cap675C'}, ...
                {'Cap675A_Gnd', 'Cap675B_Gnd', 'Cap675C_Gnd'}}
    1, 3, 135, {{'Line_671_684', 'Line_684_611', '', '', '', 'Line_684_652'}, ...
                {'L611C', 'CapBrk_611C', 'Cap611C', 'Open611A', 'Open611B', 'L652A', 'Open652B', 'Open652C'}, ...
                {'L611C_Gnd', '', 'Cap611C_Gnd', 'Open611A_Gnd', 'Open611B_Gnd', 'L652A_Gnd', 'Open652B_Gnd', 'Open652C_Gnd'}}
    3, 3, DX,  {{'Line_671_680'}, ...
                {'Open680A', 'Open680B', 'Open680C'}, ...
                {'Open680A_Gnd', 'Open680B_Gnd', 'Open680C_Gnd'}}
    4, 3, 160, {{'FaultBreaker_675A', 'FaultBreaker_675B', 'FaultBreaker_675C'}, ...
                {'Emanuel_Arc_Fault_675A', 'Emanuel_Arc_Fault_675B', 'Emanuel_Arc_Fault_675C'}, ...
                {'FaultGnd_675A', 'FaultGnd_675B', 'FaultGnd_675C'}}
    };

for sub = {'Physical_Feeder', 'Digital_Twin'}
    subPath = [sysName '/' sub{1}];
    placed = {};
    for c = 1:size(cells, 1)
        [col, row, pitch, rows] = cells{c, :};
        x0 = (col - 1) * CELL_W + MARGIN(1);
        y0 = (row - 1) * CELL_H + MARGIN(2);
        for i = 1:numel(rows)
            for j = 1:numel(rows{i})
                name = rows{i}{j};
                blk = [subPath '/' name];
                if isempty(name) || getSimulinkBlockHandle(blk) <= 0
                    continue;
                end
                moveCentre(blk, x0 + (j - 1) * pitch, y0 + (i - 1) * DY);
                placed{end + 1} = name; %#ok<AGROW>
            end
        end
    end

    names = get_param(find_system(subPath, 'SearchDepth', 1, 'Type', 'Block'), 'Name');
    names = names(~strcmp(names, sub{1}));
    unplaced = setdiff(names, placed);
    if ~isempty(unplaced)
        warning('layout_twin_system:Unplaced', '%s: no layout slot for %s (left in place).', ...
            sub{1}, strjoin(unplaced, ', '));
    end

    redrawLines(subPath);
end
end

%% ======================================================================
function redrawLines(subPath)
% Re-draw every line segment as a straight / L-shaped path between its
% endpoints. Geometry only: no line is added, deleted or reconnected.
%
% Moving a block drags the line ends glued to its ports, but junctions
% (branch points where one electrical node fans out) and intermediate
% bends stay at their old coordinates - thousands of px away after the
% move - and Simulink.BlockDiagram.routeLine does not move them.
% Physical-connection lines also do not report their ports
% (SrcPortHandle = -1), so the geometry is handled directly: every segment
% endpoint is either on a port (fixed) or a junction (identified by its
% shared coordinate). Each free junction is relaxed to the mean of the
% endpoints it connects to, then every segment is redrawn. Some junctions
% (left by earlier delete_line/add_line edits) are pinned by Simulink -
% set_param 'Points' silently keeps the old path - so the pass is
% repeated, treating every junction observed not to move as fixed, until
% the drawn geometry is self-consistent.
pinned = zeros(0, 2);
for pass = 1:6
    newlyPinned = redrawPass(subPath, pinned);
    if isempty(newlyPinned)
        break;
    end
    pinned = unique([pinned; newlyPinned], 'rows');
end
end

function newlyPinned = redrawPass(subPath, pinned)
lineH = find_system(subPath, 'SearchDepth', 1, 'FindAll', 'on', 'Type', 'line');
pts = get_param(lineH, 'Points');
if ~iscell(pts)
    pts = {pts};
end
ends = zeros(numel(lineH), 4);
for k = 1:numel(lineH)
    ends(k, :) = [pts{k}(1, :), pts{k}(end, :)];
end

% Port positions (line ends glued to these are fixed).
blocks = find_system(subPath, 'SearchDepth', 1, 'Type', 'Block');
portPos = zeros(0, 2);
for b = blocks(:)'
    if strcmp(b{1}, subPath)
        continue;
    end
    ph = get_param(b{1}, 'PortHandles');
    for f = {'Inport', 'Outport', 'LConn', 'RConn', 'Enable', 'Trigger'}
        for p = ph.(f{1})(:)'
            portPos(end + 1, :) = get_param(p, 'Position'); %#ok<AGROW>
        end
    end
end

allEnds = [ends(:, 1:2); ends(:, 3:4)];                   % 2N x 2
isPort = ismember(allEnds, portPos, 'rows');
% Junctions Simulink refused to move in an earlier pass are fixed, like ports.
isPort = isPort | ismember(allEnds, pinned, 'rows');
[junc, ~, jid] = unique(allEnds(~isPort, :), 'rows');     % free junction points
nodeOf = zeros(size(allEnds, 1), 1);                       % 0 = port end
nodeOf(~isPort) = jid;

% Relax each junction to the mean of the opposite ends of its segments.
n = numel(lineH);
newJ = junc;
for it = 1:50
    acc = zeros(size(junc));
    cnt = zeros(size(junc, 1), 1);
    for k = 1:n
        for e = [k, k + n]
            j = nodeOf(e);
            if j == 0
                continue;
            end
            other = e + n * (e <= n) - n * (e > n);
            if nodeOf(other) == 0
                p = allEnds(other, :);
            else
                p = newJ(nodeOf(other), :);
            end
            acc(j, :) = acc(j, :) + p;
            cnt(j) = cnt(j) + 1;
        end
    end
    newJ = acc ./ max(cnt, 1);
end
newJ = round(newJ);

newlyPinned = zeros(0, 2);
for k = 1:n
    a = endPoint(allEnds(k, :), nodeOf(k), newJ);
    b = endPoint(allEnds(k + n, :), nodeOf(k + n), newJ);
    planned = elbow(a, b);
    set_param(lineH(k), 'Points', planned);
    actual = get_param(lineH(k), 'Points');
    if ~isequal(actual([1 end], :), planned([1 end], :))
        % Simulink kept (part of) the old path: pin its real endpoints.
        newlyPinned = [newlyPinned; actual([1 end], :)]; %#ok<AGROW>
    end
end
newlyPinned = setdiff(unique(newlyPinned, 'rows'), [pinned; portPos], 'rows');
end

function p = endPoint(p0, j, newJ)
if j == 0
    p = p0;
else
    p = newJ(j, :);
end
end

function pts = elbow(a, b)
% Straight segment if aligned, otherwise one horizontal-then-vertical bend.
if a(1) == b(1) || a(2) == b(2)
    pts = [a; b];
else
    pts = [a; b(1) a(2); b];
end
end

%% ======================================================================
function moveCentre(blk, cx, cy)
% Translate a block so its centre is at (cx, cy); size is unchanged.
p = get_param(blk, 'Position');
w = p(3) - p(1);
h = p(4) - p(2);
set_param(blk, 'Position', round([cx - w/2, cy - h/2, cx + w/2, cy + h/2]));
end
