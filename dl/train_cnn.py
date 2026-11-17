"""End-to-end 1D-CNN on the raw residual windows (journal comparison, stage 2).

Same windows, folds and test runs as the Random Forest and LightGBM
(data/dl), unweighted cross-entropy like the relay RF. Early stopping on a
run-grouped 20 % of the TRAINING runs of each fit (hif_data.inner_split).

Training details:
  - AdamW (lr 1e-3, weight decay 1e-4), cosine schedule over MAX_EPOCHS,
    batch 128, early stopping on the held-out loss (patience 8), best epoch kept
  - time-shift augmentation: with probability 0.5 a training window is
    replaced by a crop starting 1..hop-1 samples later, cut from the window
    and its same-label successor (hif_data.shift_partner). The in-model relay
    classifies every half cycle, i.e. at window phases the one-cycle-hop
    dataset never shows; the crops are label-safe by construction
  - CPU limits from tools/cnn_hw_check.py: 4 threads (5 failed the sustained
    load check), a cool-down pause between fits and whenever an epoch runs
    more than 1.5x slower than the first epochs; refuses to run on battery
    unless --allow-battery

    python dl/train_cnn.py cv --variant slog       # 5-fold CV (resumable)
    python dl/train_cnn.py final --variant slog    # all training runs, 3 seeds
    python dl/train_cnn.py cv --variant slog --arch wide   # receptive-field ablation
                                                           # (results named cnn_wide_{variant})

Outputs:
    results/dl/cnn_{variant}/fold{k}.npz, seed{s}.npz   per-fit checkpoints of the results
    results/dl/pred_cnn_{variant}_cv.csv                out-of-fold predictions
    results/dl/pred_cnn_{variant}_test_seed{s}.csv      final models on the test runs
    models/dl/cnn_{variant}_seed{s}.pt                  final weights + scaling
    results/dl/cnn_{variant}/log.json                   per-epoch history, timings
"""
import argparse
import copy
import json
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

from hif_cnn import HifCNN, Scaling, predict_proba, receptive_field
from hif_data import (inner_split, load_dataset, on_ac_power, shift_partner, shifted_windows,
                      write_predictions)

ROOT = Path(__file__).resolve().parents[1]
RES, MOD = ROOT / 'results' / 'dl', ROOT / 'models' / 'dl'
THREADS, BATCH = 4, 128
MAX_EPOCHS, PATIENCE = 40, 8
LR, WEIGHT_DECAY = 1e-3, 1e-4
SHIFT_P = 0.5
SEEDS = (0, 1, 2)
COOL_BETWEEN_FITS_S, SLOW_FACTOR, COOL_SLOW_S = 20, 1.5, 30


def train_one(ds, mask, variant, arch, seed, partner, tag):
    torch.manual_seed(seed)
    rng = np.random.default_rng(seed)
    hop = ds.manifest['hop_len']
    fit_m, es_m = inner_split(ds, mask, 0.2, seed)
    fit_idx, es_idx = np.nonzero(fit_m)[0], np.nonzero(es_m)[0]
    scaling = Scaling.fit(variant, ds.windows[fit_idx])
    y = torch.from_numpy(ds.meta['code'])
    model = HifCNN(arch)
    opt = torch.optim.AdamW(model.parameters(), lr=LR, weight_decay=WEIGHT_DECAY)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, MAX_EPOCHS)
    loss_fn = nn.CrossEntropyLoss()
    x_es = scaling(ds.windows[es_idx])
    y_es = y[es_idx]

    best_loss, best_state, best_epoch = np.inf, None, -1
    history, epoch_times, cooldowns = [], [], 0
    t_fit = time.perf_counter()
    for epoch in range(MAX_EPOCHS):
        t0 = time.perf_counter()
        model.train()
        perm = rng.permutation(fit_idx)
        total = 0.0
        for i in range(0, len(perm), BATCH):
            idx = perm[i:i + BATCH]
            shift = np.where((partner[idx] >= 0) & (rng.random(len(idx)) < SHIFT_P),
                             rng.integers(1, hop, len(idx)), 0)
            xb = torch.from_numpy(scaling(shifted_windows(ds.windows, idx, partner, shift, hop)))
            opt.zero_grad(set_to_none=True)
            loss = loss_fn(model(xb), y[idx])
            loss.backward()
            opt.step()
            total += loss.item() * len(idx)
        sched.step()

        model.eval()
        with torch.no_grad():
            logits = torch.cat([model(torch.from_numpy(x_es[j:j + 1024])) for j in range(0, len(x_es), 1024)])
            es_loss = loss_fn(logits, y_es).item()
            es_acc = (logits.argmax(1) == y_es).float().mean().item()
        dt = time.perf_counter() - t0
        epoch_times.append(dt)
        history.append({'epoch': epoch + 1, 'train_loss': total / len(perm), 'es_loss': es_loss,
                        'es_acc': es_acc, 'seconds': round(dt, 2)})
        print(f'  {tag} epoch {epoch + 1:2d}: train {total / len(perm):.4f}  early-stop loss {es_loss:.4f} '
              f'acc {es_acc:.4f}  ({dt:.1f} s)', flush=True)
        if es_loss < best_loss:
            best_loss, best_state, best_epoch = es_loss, copy.deepcopy(model.state_dict()), epoch + 1
        elif epoch + 1 - best_epoch >= PATIENCE:
            break
        if len(epoch_times) > 3 and dt > SLOW_FACTOR * np.median(epoch_times[:3]):
            print(f'  {tag} epoch slowed to {dt:.1f} s - cooling down {COOL_SLOW_S} s', flush=True)
            cooldowns += 1
            time.sleep(COOL_SLOW_S)

    model.load_state_dict(best_state)
    info = {'tag': tag, 'arch': arch, 'seed': seed, 'best_epoch': best_epoch, 'epochs_run': len(history),
            'best_es_loss': best_loss, 'fit_windows': int(fit_m.sum()), 'early_stop_windows': int(es_m.sum()),
            'fit_s': round(time.perf_counter() - t_fit, 1), 'median_epoch_s': round(float(np.median(epoch_times)), 2),
            'cooldowns': cooldowns, 'scaling': scaling.state(), 'history': history}
    return model, scaling, info


def run_cv(ds, variant, arch, name, partner):
    out = RES / name
    out.mkdir(parents=True, exist_ok=True)
    rows, folds, probs, infos = [], [], [], []
    for k in range(1, ds.manifest['folds'] + 1):
        ck = out / f'fold{k}.npz'
        if ck.exists():
            z = np.load(ck, allow_pickle=True)
            print(f'fold {k}: loaded from {ck.name}')
            info = json.loads(str(z['info']))
        else:
            model, scaling, info = train_one(ds, ds.train_mask(exclude_fold=k), variant, arch, 0, partner, f'fold {k}')
            ev = ds.fold_mask(k)
            np.savez(ck, rows=ds.meta['row'][ev], probs=predict_proba(model, scaling, ds.windows[ev]),
                     info=json.dumps(info))
            z = np.load(ck, allow_pickle=True)
            print(f'fold {k}: best epoch {info["best_epoch"]}, {info["fit_s"]} s, cooldowns {info["cooldowns"]}')
            time.sleep(COOL_BETWEEN_FITS_S)
        rows.append(z['rows'])
        probs.append(z['probs'])
        folds.append(np.full(len(z['rows']), k))
        infos.append(info)
    write_predictions(RES / f'pred_{name}_cv.csv', np.concatenate(rows), np.concatenate(probs),
                      np.concatenate(folds))
    return infos


def run_final(ds, variant, arch, name, partner):
    out = RES / name
    out.mkdir(parents=True, exist_ok=True)
    MOD.mkdir(parents=True, exist_ok=True)
    te = ds.test_mask()
    infos = []
    for s in SEEDS:
        ck = out / f'seed{s}.npz'
        if ck.exists():
            z = np.load(ck, allow_pickle=True)
            print(f'seed {s}: loaded from {ck.name}')
            info = json.loads(str(z['info']))
        else:
            model, scaling, info = train_one(ds, ds.train_mask(), variant, arch, s, partner, f'seed {s}')
            torch.save({'state_dict': model.state_dict(), 'arch': arch, 'scaling': scaling.state(), 'info': info},
                       MOD / f'{name}_seed{s}.pt')
            np.savez(ck, rows=ds.meta['row'][te], probs=predict_proba(model, scaling, ds.windows[te]),
                     info=json.dumps(info))
            z = np.load(ck, allow_pickle=True)
            print(f'seed {s}: best epoch {info["best_epoch"]}, {info["fit_s"]} s, cooldowns {info["cooldowns"]}')
            time.sleep(COOL_BETWEEN_FITS_S)
        write_predictions(RES / f'pred_{name}_test_seed{s}.csv', z['rows'], z['probs'])
        infos.append(info)
    return infos


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('stage', choices=('cv', 'final'))
    ap.add_argument('--variant', choices=('slog', 'ref'), required=True)
    ap.add_argument('--arch', choices=('base', 'wide'), default='base')
    ap.add_argument('--allow-battery', action='store_true')
    a = ap.parse_args()
    name = f'cnn_{a.variant}' if a.arch == 'base' else f'cnn_wide_{a.variant}'
    if on_ac_power() is False and not a.allow_battery:
        raise SystemExit('On battery: timings and thermals are not representative. Plug in or pass --allow-battery.')
    torch.set_num_threads(THREADS)
    torch.set_num_interop_threads(1)

    ds = load_dataset(in_memory=True)
    partner = shift_partner(ds)
    infos = (run_cv if a.stage == 'cv' else run_final)(ds, a.variant, a.arch, name, partner)
    log_file = RES / name / 'log.json'
    log = json.loads(log_file.read_text()) if log_file.exists() else {}
    log[a.stage] = infos
    log['settings'] = {'threads': THREADS, 'batch': BATCH, 'max_epochs': MAX_EPOCHS, 'patience': PATIENCE,
                       'lr': LR, 'weight_decay': WEIGHT_DECAY, 'shift_p': SHIFT_P,
                       'arch': a.arch, 'params': sum(p.numel() for p in HifCNN(a.arch).parameters()),
                       'receptive_field_samples': receptive_field(HifCNN(a.arch))}
    log_file.write_text(json.dumps(log, indent=2))
    print(f'Saved {a.stage} results for {name}')


if __name__ == '__main__':
    main()
