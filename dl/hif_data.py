"""Loader for the relay windows exported by scripts/export_dl_dataset.m.

    from hif_data import load_dataset
    ds = load_dataset()          # project data/dl by default
    ds.windows   float32 [N, 3, 667] raw lateral residual (A), memory-mapped
    ds.features  float64 [N, 87] db4 features (= data/features.mat X)
    ds.meta      dict of per-window numpy columns from windows.csv
                 (row, run, source, lateral, tStart, label, code, split,
                 fold, faulted, adjacent, weak)

Folds and the test split are fixed in the export and shared by every model
(RF, LightGBM, 1D-CNN): fold 0 = held-out test runs, folds 1..5 = training
runs. Never split windows any other way - windows of one run overlap.

    python dl/hif_data.py        # layout self-check against the MATLAB features
"""
import csv
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np

DATA_DIR = Path(__file__).resolve().parents[1] / 'data' / 'dl'
INT_COLS = ('row', 'run', 'code', 'fold')
BOOL_COLS = ('faulted', 'adjacent', 'weak')
FLOAT_COLS = ('tStart',)


@dataclass
class Dataset:
    windows: np.ndarray
    features: np.ndarray
    meta: dict
    manifest: dict

    @property
    def class_names(self):
        return self.manifest['class_names']

    def train_mask(self, exclude_fold=None):
        m = self.meta['split'] == 'train'
        if exclude_fold is not None:
            m &= self.meta['fold'] != exclude_fold
        return m

    def fold_mask(self, fold):
        return self.meta['fold'] == fold

    def test_mask(self):
        return self.meta['split'] == 'test'


def _read_table(path):
    with open(path, newline='') as fh:
        rows = list(csv.DictReader(fh))
    cols = {}
    for name in rows[0]:
        vals = [r[name] for r in rows]
        if name in INT_COLS:
            cols[name] = np.array(vals, dtype=np.int64)
        elif name in BOOL_COLS:
            cols[name] = np.array(vals, dtype=np.int64) != 0
        elif name in FLOAT_COLS:
            cols[name] = np.array(vals, dtype=np.float64)
        else:
            cols[name] = np.array(vals)
    return cols


def load_dataset(data_dir=DATA_DIR, in_memory=False):
    data_dir = Path(data_dir)
    man = json.loads((data_dir / 'manifest.json').read_text())
    w, f = man['windows'], man['features']
    windows = np.memmap(data_dir / w['file'], dtype=w['dtype'], mode='r', shape=tuple(w['shape']))
    features = np.fromfile(data_dir / f['file'], dtype=f['dtype']).reshape(f['shape'])
    if in_memory:
        windows = np.array(windows)
    meta = _read_table(data_dir / 'windows.csv')
    n = man['n_windows']
    assert windows.shape[0] == features.shape[0] == len(meta['row']) == n, 'export files disagree on N'
    assert np.array_equal(meta['row'], np.arange(1, n + 1)), 'windows.csv rows out of order'
    return Dataset(windows, features, meta, man)


def run_kind(ds):
    """Per-window event class of the window's RUN (its HIF phase code if the
    run has HIF windows, else 1 if it has switching windows, else 0)."""
    code, run = ds.meta['code'], ds.meta['run']
    kind_of_run = np.zeros(run.max() + 1, dtype=np.int64)
    np.maximum.at(kind_of_run, run, code)
    return kind_of_run[run]


def inner_split(ds, mask, frac=0.2, seed=0):
    """Run-grouped split of the windows in `mask` into (fit, early-stopping)
    masks: `frac` of the runs of each run event class go to early stopping."""
    rng = np.random.default_rng(seed)
    run, kind = ds.meta['run'], run_kind(ds)
    val_runs = []
    for k in np.unique(kind[mask]):
        runs = np.unique(run[mask & (kind == k)])
        rng.shuffle(runs)
        val_runs.extend(runs[:max(1, round(frac * len(runs)))])
    val = mask & np.isin(run, val_runs)
    return mask & ~val, val


def shift_partner(ds):
    """Index of the next window of the same run and lateral when it starts
    exactly one hop later and carries the same label, else -1.

    A crop starting d samples (0 < d < hop) into window w then lies inside
    windows w and w + 1, and by the labelling rules of extract_features.m
    has the same label as both - a label-safe time-shift augmentation."""
    m = ds.meta
    hop_s = ds.manifest['hop_len'] / ds.manifest['fs_hz']
    lat = (m['lateral'] == '675').astype(np.int64)
    order = np.lexsort((m['tStart'], lat, m['run']))
    partner = np.full(len(order), -1, dtype=np.int64)
    a, b = order[:-1], order[1:]
    ok = ((m['run'][a] == m['run'][b]) & (lat[a] == lat[b])
          & np.isclose(m['tStart'][b] - m['tStart'][a], hop_s, atol=1e-9) & (m['code'][a] == m['code'][b]))
    partner[a[ok]] = b[ok]
    return partner


def shifted_windows(windows, idx, partner, shift, hop):
    """Raw [len(idx), 3, W] crops starting shift[i] samples into window idx[i]
    (shift 0 = the window itself; shift > 0 requires partner[idx] >= 0)."""
    out = np.array(windows[idx])
    W = out.shape[-1]
    overlap = W - hop
    for i in np.nonzero(shift)[0]:
        d = shift[i]
        nxt = windows[partner[idx[i]]]
        out[i, :, :W - d] = windows[idx[i], :, d:]
        out[i, :, W - d:] = nxt[:, overlap:overlap + d]
    return out


def write_predictions(path, rows, probs, fold=None):
    """Prediction CSV in the format scripts/score_predictions.m reads:
    row[, fold], pred, p0..p4 (pred = argmax, rows are 1-based)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    pred = probs.argmax(1)
    with open(path, 'w', newline='') as fh:
        wr = csv.writer(fh)
        wr.writerow(['row'] + (['fold'] if fold is not None else []) + ['pred'] + [f'p{c}' for c in range(probs.shape[1])])
        for i in range(len(rows)):
            wr.writerow([int(rows[i])] + ([int(fold[i])] if fold is not None else []) + [int(pred[i])]
                        + [f'{p:.6g}' for p in probs[i]])


def on_ac_power():
    """True / False / None (unknown) - whether the laptop is plugged in."""
    import ctypes
    import os
    if os.name != 'nt':
        return None

    class SPS(ctypes.Structure):
        _fields_ = [('ACLineStatus', ctypes.c_byte), ('BatteryFlag', ctypes.c_byte),
                    ('BatteryLifePercent', ctypes.c_byte), ('SystemStatusFlag', ctypes.c_byte),
                    ('BatteryLifeTime', ctypes.c_ulong), ('BatteryFullLifeTime', ctypes.c_ulong)]
    s = SPS()
    if ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(s)):
        return {0: False, 1: True}.get(s.ACLineStatus)
    return None


def _self_check():
    ds = load_dataset(in_memory=True)
    names = list(ds.manifest['feature_names'])
    print(f'{ds.manifest["n_windows"]} windows, windows {ds.windows.shape} {ds.windows.dtype}, '
          f'features {ds.features.shape}')
    # Layout check: the time-domain mean / std features of each phase must
    # equal numpy's mean / std of the exported raw window (MATLAB std is n-1).
    x = ds.windows.astype(np.float64)
    worst = 0.0
    for p, tag in enumerate('ABC'):
        mean_f = ds.features[:, names.index(f'phase{tag}_time_Mean')]
        std_f = ds.features[:, names.index(f'phase{tag}_time_Std')]
        scale = np.maximum(np.abs(std_f), 1e-12)
        worst = max(worst,
                    np.max(np.abs(x[:, p].mean(1) - mean_f) / scale),
                    np.max(np.abs(x[:, p].std(1, ddof=1) - std_f) / scale))
    print(f'max relative mismatch of per-phase mean/std vs MATLAB features: {worst:.2e}')
    assert worst < 1e-6, 'window layout does not match the MATLAB features'

    for split in ('train', 'test'):
        m = ds.meta['split'] == split
        counts = np.bincount(ds.meta['code'][m], minlength=5)
        print(f'{split:5s}: {m.sum():6d} windows, {len(np.unique(ds.meta["run"][m]))} runs, '
              f'class counts {dict(zip(ds.class_names, counts.tolist()))}')
    for k in range(1, ds.manifest['folds'] + 1):
        m = ds.fold_mask(k)
        print(f'fold {k}: {m.sum():5d} windows, {len(np.unique(ds.meta["run"][m]))} runs, '
              f'HIF windows {(ds.meta["code"][m] >= 2).sum()}, weak {ds.meta["weak"][m].sum()}')
    runs_test = set(ds.meta['run'][ds.test_mask()])
    assert not runs_test & set(ds.meta['run'][ds.train_mask()]), 'a run is in both train and test'

    # Shift augmentation: consecutive windows must overlap sample for sample.
    hop = ds.manifest['hop_len']
    partner = shift_partner(ds)
    has = np.nonzero(partner >= 0)[0]
    W = ds.windows.shape[-1]
    dev = np.max(np.abs(ds.windows[has, :, hop:] - ds.windows[partner[has], :, :W - hop]))
    print(f'shift partners: {len(has)} of {len(partner)} windows; overlap mismatch {dev:g}')
    assert dev == 0, 'consecutive windows do not overlap as expected'
    print('layout check PASSED')


if __name__ == '__main__':
    _self_check()
