"""Learning curve: does the number of training runs explain the CNN-LightGBM gap?

For each repeat r = 0, 1, 2 the 720 training runs are shuffled within each
stratum (run event class x main / boundary dataset, rng 5000 + r) and nested
subsets of 25 / 50 / 75 % of the runs are taken (a run enters with all of its
windows; early stopping uses 20 % of the subset's runs, run-grouped). The wide
1D-CNN (reference scaling) and LightGBM are trained on each subset with the
unchanged recipes and seed r, and predict the 180 held-out test runs. The
100 % point is the existing final models (seeds 0-2, trained the same way on
all training runs). The RF counterpart, on the same subsets, is
scripts/learning_curve_rf.m; scoring and figure: scripts/learning_curve_analysis.m.

    python dl/learning_curve.py          # resumable: finished subsets are skipped

Outputs (results/dl/learning_curve/):
    subsets.csv                          run, repeat, in25, in50, in75 (training runs only)
    pred_{lgbm,cnn_wide_ref}_f{25,50,75,100}_r{0,1,2}.csv   test predictions
    log.json
"""
import csv
import json
import shutil
import sys
import time
from pathlib import Path

import numpy as np
import torch

import train_cnn
import train_lgbm
from hif_cnn import predict_proba
from hif_data import load_dataset, on_ac_power, run_kind, shift_partner, write_predictions

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'results' / 'dl' / 'learning_curve'
RES = ROOT / 'results' / 'dl'
FRACTIONS = (25, 50, 75)
REPEATS = (0, 1, 2)


def make_subsets(ds):
    m = ds.meta
    tr = ds.train_mask()
    kind = run_kind(ds)
    runs = np.unique(m['run'][tr])
    run_kind_of = {r: k for r, k in zip(m['run'][tr], kind[tr])}
    run_src_of = {r: s for r, s in zip(m['run'][tr], m['source'][tr])}
    member = {}
    for rep in REPEATS:
        rng = np.random.default_rng(5000 + rep)
        strata = {}
        for r in runs:
            strata.setdefault((run_kind_of[r], run_src_of[r]), []).append(r)
        for key in sorted(strata):
            rs = np.array(sorted(strata[key]))
            rng.shuffle(rs)
            for i, r in enumerate(rs):
                member[(rep, r)] = {f: i < int(np.ceil(f / 100 * len(rs))) for f in FRACTIONS}
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / 'subsets.csv', 'w', newline='') as fh:
        wr = csv.writer(fh)
        wr.writerow(['run', 'repeat'] + [f'in{f}' for f in FRACTIONS])
        for (rep, r), v in sorted(member.items()):
            wr.writerow([int(r), rep] + [int(v[f]) for f in FRACTIONS])
    return member


def main():
    allow_battery = '--allow-battery' in sys.argv[1:]
    if on_ac_power() is False and not allow_battery:
        raise SystemExit('On battery: plug in before training, or pass --allow-battery.')
    torch.set_num_threads(train_cnn.THREADS)
    torch.set_num_interop_threads(1)
    ds = load_dataset(in_memory=True)
    partner = shift_partner(ds)
    member = make_subsets(ds)
    te = ds.test_mask()
    log_file = OUT / 'log.json'
    log = json.loads(log_file.read_text()) if log_file.exists() else []

    # the 100 % point = the existing final models
    for rep in REPEATS:
        for name in ('lgbm', 'cnn_wide_ref'):
            shutil.copyfile(RES / f'pred_{name}_test_seed{rep}.csv', OUT / f'pred_{name}_f100_r{rep}.csv')

    for f in FRACTIONS:
        for rep in REPEATS:
            runs = [r for (q, r), v in member.items() if q == rep and v[f]]
            mask = ds.train_mask() & np.isin(ds.meta['run'], runs)
            entry = {'fraction': f, 'repeat': rep, 'runs': len(runs), 'windows': int(mask.sum())}
            path = OUT / f'pred_lgbm_f{f}_r{rep}.csv'
            if not path.exists():
                booster, info = train_lgbm.fit(ds, mask, seed=rep)
                write_predictions(path, ds.meta['row'][te],
                                  booster.predict(ds.features[te], num_iteration=booster.best_iteration))
                entry['lgbm'] = info
            path = OUT / f'pred_cnn_wide_ref_f{f}_r{rep}.csv'
            if not path.exists():
                model, scaling, info = train_cnn.train_one(ds, mask, 'ref', 'wide', rep, partner, f'f{f} r{rep}')
                write_predictions(path, ds.meta['row'][te], predict_proba(model, scaling, ds.windows[te]))
                entry['cnn'] = {k: v for k, v in info.items() if k != 'history'}
                time.sleep(train_cnn.COOL_BETWEEN_FITS_S)
            print(f'{f} % repeat {rep}: {len(runs)} runs, {int(mask.sum())} windows done', flush=True)
            log.append(entry)
            log_file.write_text(json.dumps(log, indent=2))
    print('Saved results/dl/learning_curve/*')


if __name__ == '__main__':
    main()
