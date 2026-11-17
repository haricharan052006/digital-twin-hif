"""LightGBM and 1D-CNN predictions on the noisy test windows (stage 3).

Reads the windows / features written by scripts/export_noisy_test.m (identical
noise for every model; the RF is predicted there) and predicts every final
model: models/dl/lgbm_seed{s}.txt and models/dl/cnn_{variant}_seed{s}.pt.

    python dl/predict_noise.py

Outputs: results/dl/noise/pred_{model}_seed{s}_sigma{i}.csv (i = 1-based
sigma index of data/dl/noise/noise.json), scored by scripts/score_noise.m.
"""
import json
from pathlib import Path

import lightgbm as lgb
import numpy as np
import torch

from hif_cnn import load_checkpoint, predict_proba
from hif_data import write_predictions

ROOT = Path(__file__).resolve().parents[1]
NOISE, MOD, OUT = ROOT / 'data' / 'dl' / 'noise', ROOT / 'models' / 'dl', ROOT / 'results' / 'dl' / 'noise'


def main():
    torch.set_num_threads(4)
    info = json.loads((NOISE / 'noise.json').read_text())
    rows = np.asarray(info['rows'])
    n, c, w = info['shape']
    models = {}
    for p in sorted(MOD.glob('lgbm*_seed*.txt')):          # lgbm_seed<s>, lgbm_aug_seed<s>
        name, seed = p.stem.rsplit('_seed', 1)
        models[(name, seed)] = ('lgbm', lgb.Booster(model_file=str(p)))
    for p in sorted(MOD.glob('cnn_*_seed*.pt')):
        name, seed = p.stem.rsplit('_seed', 1)
        models[(name, seed)] = ('cnn', load_checkpoint(p)[:2])
    print(f'{len(models)} models: {sorted(models)}')
    for i, sigma in enumerate(info['sigmas'], start=1):
        win = np.fromfile(NOISE / f'windows_sigma{i}.bin', dtype=np.float32).reshape(n, c, w)
        feat = np.fromfile(NOISE / f'features_sigma{i}.bin', dtype=np.float64).reshape(n, info['n_features'])
        for (name, seed), (kind, m) in models.items():
            if kind == 'lgbm':
                probs = m.predict(feat, num_threads=4)
            else:
                probs = predict_proba(m[0], m[1], win)
            write_predictions(OUT / f'pred_{name}_seed{seed}_sigma{i}.csv', rows, probs)
        print(f'sigma {sigma:g} A done', flush=True)


if __name__ == '__main__':
    main()
