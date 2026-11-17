"""Training sanity check of the 1D-CNN pipeline (stage 2 diagnostics).

Rules out pipeline bugs before reading the CNN's cross-validation result as a
property of the model:
  1. receptive field of the network (samples / ms / cycles at 20 kHz, 60 Hz)
  2. memorisation test: a small class-balanced subset of fold-1 training
     windows, NO augmentation, no dropout effect at eval - a working
     pipeline must drive training accuracy to ~100 %
  3. gradient norm per layer at the first and last step (no vanishing /
     exploding gradients), and the fraction of dead ReLU outputs and the
     activation scale per block (activations flowing)
for both input scalings.

    python dl/sanity_cnn.py
"""
import numpy as np
import torch
import torch.nn as nn

from hif_cnn import HifCNN, Scaling, receptive_field
from hif_data import load_dataset

PER_CLASS, STEPS, BATCH = 100, 400, 128


def grad_norms(model):
    return {n: round(p.grad.norm().item(), 4) for n, p in model.named_parameters()
            if p.grad is not None and 'weight' in n and p.dim() > 1}


def activation_stats(model, x):
    stats, h = [], x
    model.eval()
    with torch.no_grad():
        for blk in model.features:
            h = blk(h)
            stats.append({'dead_frac': round((h == 0).float().mean().item(), 3),
                          'std': round(h.std().item(), 4)})
    return stats


def main():
    torch.set_num_threads(4)
    ds = load_dataset(in_memory=True)
    rng = np.random.default_rng(0)
    pool = ds.train_mask(exclude_fold=1)
    idx = np.concatenate([rng.choice(np.nonzero(pool & (ds.meta['code'] == c))[0], PER_CLASS, replace=False)
                          for c in range(5)])
    y = torch.from_numpy(ds.meta['code'][idx])
    for arch in ('base', 'wide'):
        m = HifCNN(arch)
        rf = receptive_field(m)
        print(f'{arch}: receptive field {rf} samples = {rf / 20:.2f} ms = {rf / (20000 / 60):.2f} cycles at 60 Hz '
              f'(window {ds.windows.shape[-1]} samples), {sum(p.numel() for p in m.parameters())} parameters')
    scalings = {k: Scaling.fit(k, ds.windows[np.nonzero(pool)[0]]) for k in ('slog', 'ref')}
    for arch, kind in (('base', 'slog'), ('base', 'ref'), ('wide', 'slog'), ('wide', 'ref')):
        torch.manual_seed(0)
        scaling = scalings[kind]
        x = torch.from_numpy(scaling(ds.windows[idx]))
        model = HifCNN(arch)
        opt = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=0)
        loss_fn = nn.CrossEntropyLoss()
        print(f'\n=== {arch} / {kind} (scaled input: mean {x.mean():.3f}, std {x.std():.3f}, '
              f'max |x| {x.abs().max():.2f})')
        print('activations at init:', activation_stats(model, x))
        for step in range(STEPS):
            model.train()
            b = torch.from_numpy(rng.choice(len(idx), BATCH, replace=False))
            opt.zero_grad(set_to_none=True)
            loss = loss_fn(model(x[b]), y[b])
            loss.backward()
            if step == 0:
                print('grad norms step 1:', grad_norms(model))
            opt.step()
            if (step + 1) % 100 == 0:
                model.eval()
                with torch.no_grad():
                    acc = (model(x).argmax(1) == y).float().mean().item()
                print(f'step {step + 1}: batch loss {loss.item():.4f}, subset train accuracy {acc:.4f}')
        print(f'grad norms step {STEPS}:', grad_norms(model))
        print('activations after training:', activation_stats(model, x))
        model.eval()
        with torch.no_grad():
            pred = model(x).argmax(1)
        print('per-class subset accuracy:', [round((pred[y == c] == c).float().mean().item(), 3) for c in range(5)])


if __name__ == '__main__':
    main()
