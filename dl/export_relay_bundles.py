"""Export the final LightGBM and 1D-CNN models for the in-model MATLAB relay (stage 4).

HIFRelayBlock.m runs inside ieee13_hif_twin_system.slx in interpreted MATLAB,
so each model is written as plain arrays (JSON) that
scripts/build_dl_relay_bundles.m turns into relay bundles:

  LightGBM  every tree flattened into global node arrays: split feature
            (0-based), threshold, left / right child (>= 0 internal node,
            < 0 leaf -(i+1)), leaf value, leaf class (tree index mod 5),
            root of each tree. Rule: x[feature] <= threshold -> left.
  CNN       per block: conv weight (C-order [Cout, Cin, K]), stride,
            dilation, padding, BatchNorm gamma / beta / running mean / var /
            eps; head linear weight (C-order [5, 128]) and bias; input scaling.

Which of the three final seeds is deployed is decided by each seed's own
early-stopping loss on its run-grouped early-stopping split - never by the
test runs. Outputs: models/dl/relay_export_{lgbm,cnn_wide_ref}.json.

    python dl/export_relay_bundles.py

Noise-augmented models (dl/train_noise_aug.py):
    python dl/export_relay_bundles.py --lgbm lgbm_aug --cnn cnn_wide_ref_aug
writes relay_export_lgbm_aug.json / relay_export_cnn_wide_ref_aug.json; the
LightGBM seed is then chosen on the augmented early-stopping split it was
trained with.
"""
import argparse
import json
from pathlib import Path

import lightgbm as lgb
import numpy as np

from hif_cnn import load_checkpoint, receptive_field
from hif_data import inner_split, load_dataset

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / 'models' / 'dl'


def multi_logloss(probs, y):
    return float(-np.mean(np.log(np.clip(probs[np.arange(len(y)), y], 1e-15, 1))))


def flatten_lgbm(booster):
    dump = booster.dump_model()
    k = dump['num_class']
    feat, thr, left, right, leaf_val, leaf_cls, roots = [], [], [], [], [], [], []

    def walk(node, cls):
        if 'split_index' not in node:
            leaf_val.append(node['leaf_value'])
            leaf_cls.append(cls)
            return -len(leaf_val)                      # leaf i (0-based) -> -(i + 1)
        assert node['decision_type'] == '<=', node['decision_type']
        assert node['missing_type'] in ('None', 'NaN'), node['missing_type']
        i = len(feat)
        feat.append(node['split_feature'])
        thr.append(node['threshold'])
        left.append(None)
        right.append(None)
        left[i] = walk(node['left_child'], cls)
        right[i] = walk(node['right_child'], cls)
        return i

    for t, tree in enumerate(dump['tree_info']):
        roots.append(walk(tree['tree_structure'], t % k))
    return {'num_class': k, 'num_trees': len(roots), 'feature': feat, 'threshold': thr, 'left': left,
            'right': right, 'leaf_value': leaf_val, 'leaf_class': leaf_cls, 'root': roots}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--lgbm', default='lgbm', help='LightGBM model name (models/dl/<name>_seed<s>.txt)')
    ap.add_argument('--cnn', default='cnn_wide_ref', help='CNN model name (models/dl/<name>_seed<s>.pt)')
    a = ap.parse_args()
    CNN_NAME = a.cnn
    ds = load_dataset(in_memory=True)
    es_ds = ds
    if a.lgbm.endswith('_aug'):
        from train_noise_aug import load_augmented
        es_ds = load_augmented(ds)[0]           # the split the augmented models early-stopped on
    y = es_ds.meta['code']

    # ---------------------------------------------------------------- LightGBM
    losses = {}
    for p in sorted(MOD.glob(f'{a.lgbm}_seed*.txt')):
        s = int(p.stem.rsplit('_seed', 1)[1])
        b = lgb.Booster(model_file=str(p))
        _, es = inner_split(es_ds, es_ds.train_mask(), 0.2, s)
        losses[s] = multi_logloss(b.predict(es_ds.features[es]), y[es])
    seed = min(losses, key=losses.get)
    b = lgb.Booster(model_file=str(MOD / f'{a.lgbm}_seed{seed}.txt'))
    lg = flatten_lgbm(b)
    lg.update({'seed': seed, 'early_stop_logloss': losses, 'model_file': f'{a.lgbm}_seed{seed}.txt'})
    (MOD / f'relay_export_{a.lgbm}.json').write_text(json.dumps(lg))
    print(f'LightGBM {a.lgbm}: early-stopping logloss by seed {losses} -> seed {seed}, '
          f'{lg["num_trees"]} trees, {len(lg["feature"])} splits, {len(lg["leaf_value"])} leaves')

    # --------------------------------------------------------------------- CNN
    cks = {}
    for p in sorted(MOD.glob(f'{CNN_NAME}_seed*.pt')):
        model, scaling, ck = load_checkpoint(p)
        cks[int(p.stem.rsplit('seed', 1)[1])] = (model, scaling, ck)
    losses = {s: v[2]['info']['best_es_loss'] for s, v in cks.items()}
    seed = min(losses, key=losses.get)
    model, scaling, ck = cks[seed]
    blocks = []
    for blk in model.features:
        conv, bn = blk[0], blk[1]
        blocks.append({'weight': conv.weight.detach().numpy().ravel().tolist(),
                       'shape': list(conv.weight.shape), 'stride': conv.stride[0],
                       'dilation': conv.dilation[0], 'padding': conv.padding[0],
                       'gamma': bn.weight.detach().numpy().tolist(), 'beta': bn.bias.detach().numpy().tolist(),
                       'mean': bn.running_mean.numpy().tolist(), 'var': bn.running_var.numpy().tolist(),
                       'eps': bn.eps})
    lin = model.head[1]
    cnn = {'arch': model.arch, 'receptive_field': receptive_field(model), 'seed': seed,
           'early_stop_loss': losses, 'scaling': ck['scaling'], 'blocks': blocks,
           'head_weight': lin.weight.detach().numpy().ravel().tolist(), 'head_shape': list(lin.weight.shape),
           'head_bias': lin.bias.detach().numpy().tolist(), 'model_file': f'{CNN_NAME}_seed{seed}.pt'}
    (MOD / f'relay_export_{CNN_NAME}.json').write_text(json.dumps(cnn))
    print(f'CNN {CNN_NAME}: early-stopping loss by seed {losses} -> seed {seed}, '
          f'{len(blocks)} blocks, receptive field {cnn["receptive_field"]} samples')


if __name__ == '__main__':
    main()
