"""Compute footprint of the 1D-CNN and LightGBM relay classifiers (stage 3).

Edge-relay conditions: one decision at a time (batch 1) on the held-out
test windows, single-threaded (and the CNN also with 4 threads). The Random
Forest and the db4 feature extraction LightGBM also needs are profiled in
MATLAB, where the relay runs (scripts/profile_rf_compute.m).

    python dl/profile_compute.py --cnn cnn_slog cnn_wide_slog

Reports per model: parameters / tree nodes, stored size, multiply-accumulates
(CNN) or node comparisons per decision (LightGBM, from the leaves reached on
the test windows), and per-decision latency (median, p99) including the input
scaling (CNN). Writes results/dl/compute_python.json.
"""
import argparse
import json
import time
from pathlib import Path

import lightgbm as lgb
import numpy as np
import torch
import torch.nn as nn

from hif_cnn import load_checkpoint, receptive_field
from hif_data import load_dataset

ROOT = Path(__file__).resolve().parents[1]
MOD, RES = ROOT / 'models' / 'dl', ROOT / 'results' / 'dl'


def latency(fn, inputs, warmup=50):
    for x in inputs[:warmup]:
        fn(x)
    t = np.empty(len(inputs))
    for i, x in enumerate(inputs):
        t0 = time.perf_counter()
        fn(x)
        t[i] = time.perf_counter() - t0
    return {'median_ms': float(np.median(t) * 1e3), 'p99_ms': float(np.percentile(t, 99) * 1e3),
            'mean_ms': float(t.mean() * 1e3), 'n': len(t)}


def cnn_macs(model, w):
    macs = []

    def hook(m, _, out):
        if isinstance(m, nn.Conv1d):
            macs.append(out.numel() * m.in_channels // m.groups * m.kernel_size[0])
        elif isinstance(m, nn.Linear):
            macs.append(m.in_features * m.out_features)
    hs = [m.register_forward_hook(hook) for m in model.modules() if isinstance(m, (nn.Conv1d, nn.Linear))]
    with torch.no_grad():
        model(torch.zeros(1, 3, w))
    for h in hs:
        h.remove()
    return int(sum(macs))


def leaf_depths(tree):
    """{leaf_index: depth} of one tree of LightGBM's dump_model()."""
    out, stack = {}, [(tree['tree_structure'], 0)]
    while stack:
        node, d = stack.pop()
        if 'leaf_index' in node or 'split_index' not in node:
            out[node.get('leaf_index', 0)] = d
        else:
            stack += [(node['left_child'], d + 1), (node['right_child'], d + 1)]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cnn', nargs='+', default=['cnn_slog'],
                    help='final CNN model names (models/dl/<name>_seed0.pt)')
    a = ap.parse_args()
    ds = load_dataset(in_memory=True)
    te = ds.test_mask()
    win, feat = ds.windows[te], ds.features[te]
    report = {'test_windows': int(te.sum()), 'cnn': []}
    xs = [win[i:i + 1] for i in range(len(win))]

    # ------------------------------------------------------------------ CNN
    for name in a.cnn:
        model, scaling, ck = load_checkpoint(MOD / f'{name}_seed0.pt')
        n_par = sum(p.numel() for p in model.parameters())
        n_buf = sum(b.numel() for b in model.buffers() if b.dtype.is_floating_point)

        def cnn_decide(x):
            with torch.no_grad():
                return int(model(torch.from_numpy(scaling(x))).argmax())
        cnn = {'model': name, 'arch': model.arch, 'receptive_field_samples': receptive_field(model),
               'parameters': n_par, 'bn_buffers': n_buf, 'stored_kb_float32': round((n_par + n_buf) * 4 / 1024, 1),
               'macs_per_decision': cnn_macs(model, win.shape[-1])}
        for th in (1, 4):
            torch.set_num_threads(th)
            cnn[f'latency_{th}thread'] = latency(cnn_decide, xs)
        report['cnn'].append(cnn)
        print('CNN', json.dumps(cnn, indent=1))

    # ------------------------------------------------------------- LightGBM
    report['lgbm'] = []
    for p in sorted(MOD.glob('lgbm_seed*.txt')):
        b = lgb.Booster(model_file=str(p))
        dump = b.dump_model()
        depths = [leaf_depths(t) for t in dump['tree_info']]
        leaves = b.predict(feat, pred_leaf=True, num_threads=1).astype(int)   # [N x trees]
        comparisons = np.array([sum(depths[t][leaves[i, t]] for t in range(leaves.shape[1]))
                                for i in range(len(leaves))])
        n_leaves = sum(len(d) for d in depths)
        rows = [feat[i:i + 1] for i in range(len(feat))]
        info = {'model': p.stem, 'trees': b.num_trees(), 'boosting_rounds': b.num_trees() // 5,
                'leaves': n_leaves, 'internal_nodes': n_leaves - b.num_trees(),
                'stored_kb_text': round(p.stat().st_size / 1024, 1),
                'node_comparisons_per_decision_mean': float(comparisons.mean()),
                'latency_1thread_python_call': latency(lambda r: b.predict(r, num_threads=1), rows[:2000])}
        report['lgbm'].append(info)
        print('LightGBM', json.dumps(info, indent=1))
    (RES / 'compute_python.json').write_text(json.dumps(report, indent=2))
    print('Saved results/dl/compute_python.json')


if __name__ == '__main__':
    main()
