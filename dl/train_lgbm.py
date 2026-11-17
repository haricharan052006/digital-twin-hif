"""LightGBM benchmark on the 87 db4 window features (journal comparison, stage 2).

Same windows, folds and test runs as the deployed Random Forest
(data/dl, scripts/export_dl_dataset.m) and unweighted classes like the
relay RF. Early stopping uses a run-grouped 20 % of the TRAINING runs of
each fit (hif_data.inner_split) - never the evaluated fold or the test runs.

    python dl/train_lgbm.py              # 5-fold CV + final models (3 seeds)

Outputs:
    results/dl/pred_lgbm_cv.csv               out-of-fold predictions
    results/dl/pred_lgbm_test_seed{s}.csv     final models on the test runs
    models/dl/lgbm_seed{s}.txt                final boosters (LightGBM text format)
    results/dl/lgbm_log.json                  rounds, timings, parameters
"""
import json
import time
from pathlib import Path

import lightgbm as lgb
import numpy as np

from hif_data import inner_split, load_dataset, write_predictions

ROOT = Path(__file__).resolve().parents[1]
RES, MOD = ROOT / 'results' / 'dl', ROOT / 'models' / 'dl'
SEEDS = (0, 1, 2)
THREADS = 4
MAX_ROUNDS, EARLY_STOP = 2000, 100
PARAMS = dict(objective='multiclass', num_class=5, learning_rate=0.05, num_leaves=31,
              min_data_in_leaf=20, feature_fraction=0.8, bagging_fraction=0.8, bagging_freq=1,
              lambda_l2=1.0, num_threads=THREADS, verbose=-1, deterministic=True, force_row_wise=True)


def fit(ds, mask, seed):
    fit_m, es_m = inner_split(ds, mask, 0.2, seed)
    X, y = ds.features, ds.meta['code']
    t0 = time.perf_counter()
    booster = lgb.train({**PARAMS, 'seed': seed}, lgb.Dataset(X[fit_m], y[fit_m]), MAX_ROUNDS,
                        valid_sets=[lgb.Dataset(X[es_m], y[es_m])],
                        callbacks=[lgb.early_stopping(EARLY_STOP, verbose=False)])
    return booster, {'seed': seed, 'best_iteration': booster.best_iteration,
                     'fit_s': round(time.perf_counter() - t0, 1),
                     'fit_windows': int(fit_m.sum()), 'early_stop_windows': int(es_m.sum())}


def main():
    ds = load_dataset()
    log = {'params': PARAMS, 'max_rounds': MAX_ROUNDS, 'early_stop': EARLY_STOP, 'cv': [], 'final': []}
    rows, folds, probs = [], [], []
    for k in range(1, ds.manifest['folds'] + 1):
        booster, info = fit(ds, ds.train_mask(exclude_fold=k), seed=0)
        ev = ds.fold_mask(k)
        rows.append(ds.meta['row'][ev])
        folds.append(np.full(ev.sum(), k))
        probs.append(booster.predict(ds.features[ev], num_iteration=booster.best_iteration))
        log['cv'].append({'fold': k, **info})
        print(f'fold {k}: {info}')
    write_predictions(RES / 'pred_lgbm_cv.csv', np.concatenate(rows), np.concatenate(probs), np.concatenate(folds))

    MOD.mkdir(parents=True, exist_ok=True)
    te = ds.test_mask()
    for s in SEEDS:
        booster, info = fit(ds, ds.train_mask(), seed=s)
        booster.save_model(str(MOD / f'lgbm_seed{s}.txt'), num_iteration=booster.best_iteration)
        write_predictions(RES / f'pred_lgbm_test_seed{s}.csv', ds.meta['row'][te],
                          booster.predict(ds.features[te], num_iteration=booster.best_iteration))
        log['final'].append(info)
        print(f'final seed {s}: {info}')
    (RES / 'lgbm_log.json').write_text(json.dumps(log, indent=2))
    print('Saved results/dl/pred_lgbm_*.csv, models/dl/lgbm_seed*.txt, results/dl/lgbm_log.json')


if __name__ == '__main__':
    main()
