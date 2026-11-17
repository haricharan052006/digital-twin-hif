"""Model internals for the comparative report: LightGBM gain importance per
feature and 1D-CNN training histories, read from the saved final models.

    python dl/extract_extras.py

Output: results/dl/comparative/extras.json
"""
import json
from pathlib import Path

import lightgbm as lgb
import numpy as np

from hif_cnn import load_checkpoint

ROOT = Path(__file__).resolve().parents[1]
MOD, OUT = ROOT / 'models' / 'dl', ROOT / 'results' / 'dl' / 'comparative'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    out = {'lgbm': {}, 'cnn': {}}
    for name in ('lgbm', 'lgbm_aug'):
        gains, trees = [], []
        for p in sorted(MOD.glob(f'{name}_seed*.txt')):
            b = lgb.Booster(model_file=str(p))
            g = b.feature_importance('gain').astype(float)
            gains.append(g / g.sum())
            trees.append(b.num_trees())
        out['lgbm'][name] = {'gain_share': np.mean(gains, axis=0).tolist(), 'trees': trees}
    for name in ('cnn_ref', 'cnn_wide_ref', 'cnn_wide_ref_aug'):
        runs = []
        for p in sorted(MOD.glob(f'{name}_seed*.pt')):
            ck = load_checkpoint(p)[2]
            info = ck['info']
            runs.append({'seed': info['seed'], 'best_epoch': info['best_epoch'],
                         'best_es_loss': info['best_es_loss'], 'fit_windows': info['fit_windows'],
                         'train_loss': [h['train_loss'] for h in info['history']],
                         'es_loss': [h['es_loss'] for h in info['history']],
                         'es_acc': [h['es_acc'] for h in info['history']]})
        out['cnn'][name] = runs
    (OUT / 'extras.json').write_text(json.dumps(out))
    print('Saved results/dl/comparative/extras.json')


if __name__ == '__main__':
    main()
