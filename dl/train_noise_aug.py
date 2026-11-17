"""Noise-augmented retraining of LightGBM and the wide 1D-CNN (journal study).

Training set = the clean training windows + the noisy copies written by
scripts/export_noise_augmented_train.m (data/dl/aug, sigma log-uniform 5 mA to
0.1 A, its own random stream); the RF counterpart is
scripts/train_rf_noise_aug.m. Same recipes as the clean models
(train_lgbm.fit, train_cnn.train_one: unchanged hyperparameters, 20 %
run-grouped early stopping - noisy copies stay with their run), 3 seeds each.
The CNN's time-shift crops use clean windows only, so no crop splices two
different noise levels; the noisy copies enter unshifted.

    python dl/train_noise_aug.py                  # both models (resumable per seed)
    python dl/train_noise_aug.py --allow-battery  # also on battery (slower; results identical)

Outputs:
    models/dl/lgbm_aug_seed{s}.txt, models/dl/cnn_wide_ref_aug_seed{s}.pt
    results/dl/pred_lgbm_aug_test_seed{s}.csv, pred_cnn_wide_ref_aug_test_seed{s}.csv
    results/dl/noise_aug_log.json
"""
import csv
import json
import sys
import time
from pathlib import Path

import numpy as np
import torch

import train_cnn
import train_lgbm
from hif_cnn import predict_proba
from hif_data import Dataset, load_dataset, on_ac_power, shift_partner, write_predictions

ROOT = Path(__file__).resolve().parents[1]
AUG = ROOT / 'data' / 'dl' / 'aug'
MOD, RES = ROOT / 'models' / 'dl', ROOT / 'results' / 'dl'
SEEDS = (0, 1, 2)


def load_augmented(ds):
    """Dataset of clean windows + noisy copies (copies inherit their source
    window's metadata, so run grouping, labels and splits carry over)."""
    info = json.loads((AUG / 'aug.json').read_text())
    n = info['n']
    win = np.fromfile(AUG / 'windows_f32.bin', dtype=np.float32).reshape(info['shape'])
    feat = np.fromfile(AUG / 'features_f64.bin', dtype=np.float64).reshape(n, info['n_features'])
    with open(AUG / 'windows_aug.csv', newline='') as fh:
        src = np.array([int(r['source_row']) for r in csv.DictReader(fh)]) - 1
    assert len(src) == n and np.all(ds.meta['split'][src] == 'train'), 'augmented copies must come from training windows'
    meta = {k: np.concatenate([v, v[src]]) for k, v in ds.meta.items()}
    meta['aug'] = np.r_[np.zeros(len(ds.meta['row']), bool), np.ones(n, bool)]
    big = Dataset(np.concatenate([ds.windows, win]), np.concatenate([ds.features, feat]), meta, ds.manifest)
    partner = np.r_[shift_partner(ds), -np.ones(n, dtype=np.int64)]   # shift crops: clean windows only
    return big, partner, info


def main():
    allow_battery = '--allow-battery' in sys.argv[1:]
    if on_ac_power() is False and not allow_battery:
        raise SystemExit('On battery: plug in before training, or pass --allow-battery.')
    torch.set_num_threads(train_cnn.THREADS)
    torch.set_num_interop_threads(1)
    ds = load_dataset(in_memory=True)
    big, partner, info = load_augmented(ds)
    te = ds.test_mask()
    print(f'training rows: {ds.train_mask().sum()} clean + {info["n"]} noisy = {big.train_mask().sum()}', flush=True)
    log = {'augmentation': info, 'lgbm': [], 'cnn': []}

    for s in SEEDS:
        path = MOD / f'lgbm_aug_seed{s}.txt'
        if path.exists():
            print(f'LightGBM seed {s}: exists')
            continue
        booster, fit_info = train_lgbm.fit(big, big.train_mask(), seed=s)
        booster.save_model(str(path), num_iteration=booster.best_iteration)
        write_predictions(RES / f'pred_lgbm_aug_test_seed{s}.csv', ds.meta['row'][te],
                          booster.predict(ds.features[te], num_iteration=booster.best_iteration))
        log['lgbm'].append(fit_info)
        print(f'LightGBM seed {s}: {fit_info}', flush=True)

    for s in SEEDS:
        path = MOD / f'cnn_wide_ref_aug_seed{s}.pt'
        if path.exists():
            print(f'CNN seed {s}: exists')
            continue
        model, scaling, fit_info = train_cnn.train_one(big, big.train_mask(), 'ref', 'wide', s, partner, f'aug seed {s}')
        torch.save({'state_dict': model.state_dict(), 'arch': 'wide', 'scaling': scaling.state(), 'info': fit_info,
                    'augmentation': info}, path)
        write_predictions(RES / f'pred_cnn_wide_ref_aug_test_seed{s}.csv', ds.meta['row'][te],
                          predict_proba(model, scaling, ds.windows[te]))
        fit_info = {k: v for k, v in fit_info.items() if k != 'history'}
        log['cnn'].append(fit_info)
        print(f'CNN seed {s}: best epoch {fit_info["best_epoch"]}, {fit_info["fit_s"]} s, '
              f'cooldowns {fit_info["cooldowns"]}', flush=True)
        time.sleep(train_cnn.COOL_BETWEEN_FITS_S)

    log_file = RES / 'noise_aug_log.json'
    old = json.loads(log_file.read_text()) if log_file.exists() else {}
    for k in ('lgbm', 'cnn'):
        log[k] = old.get(k, []) + log[k]
    log_file.write_text(json.dumps(log, indent=2))
    print('Saved noise-augmented LightGBM / CNN models and test predictions')


if __name__ == '__main__':
    main()
