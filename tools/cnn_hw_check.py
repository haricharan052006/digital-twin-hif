"""CPU training feasibility check for the proposed 1D-CNN HIF classifier.

Builds the planned ~26k-parameter 1D-CNN, runs synthetic training steps on a
dummy batch (128 x 3 x 667) and reports step time, memory, a sustained-load
throttling ratio and the projected cross-validation time. No real data used.

    python cnn_hw_check.py                 # 60 s sustained test
    python cnn_hw_check.py --seconds 180   # longer thermal test
    python cnn_hw_check.py --threads 6
"""
import argparse
import ctypes
import os
import platform
import sys
import time

import torch
import torch.nn as nn

# dataset / protocol of the planned study
N_WINDOWS = 25803
TRAIN_FRACTION = 0.8 * 0.8          # 80 % training runs, 20 % of those held for early stopping
FOLDS, SEEDS, EPOCHS = 5, 3, 40
BATCH, CHANNELS, SAMPLES, CLASSES = 128, 3, 667, 5
DECISION_BUDGET_MS = 8.35


def rss_mb():
    """Resident memory of this process in MB (no extra packages)."""
    if os.name == 'nt':
        class PMC(ctypes.Structure):
            _fields_ = [('cb', ctypes.c_ulong), ('PageFaultCount', ctypes.c_ulong),
                        ('PeakWorkingSetSize', ctypes.c_size_t), ('WorkingSetSize', ctypes.c_size_t),
                        ('QuotaPeakPagedPoolUsage', ctypes.c_size_t), ('QuotaPagedPoolUsage', ctypes.c_size_t),
                        ('QuotaPeakNonPagedPoolUsage', ctypes.c_size_t), ('QuotaNonPagedPoolUsage', ctypes.c_size_t),
                        ('PagefileUsage', ctypes.c_size_t), ('PeakPagefileUsage', ctypes.c_size_t)]
        c = PMC()
        c.cb = ctypes.sizeof(PMC)
        k32 = ctypes.windll.kernel32
        k32.GetCurrentProcess.restype = ctypes.c_void_p
        k32.K32GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.POINTER(PMC), ctypes.c_ulong]
        k32.K32GetProcessMemoryInfo(k32.GetCurrentProcess(), ctypes.byref(c), c.cb)
        return c.WorkingSetSize / 2**20, c.PeakWorkingSetSize / 2**20
    import resource
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    peak = peak / 2**20 if sys.platform == 'darwin' else peak / 1024
    return peak, peak


def on_ac_power():
    """True / False / None (unknown) - whether the laptop is plugged in."""
    if os.name == 'nt':
        class SPS(ctypes.Structure):
            _fields_ = [('ACLineStatus', ctypes.c_byte), ('BatteryFlag', ctypes.c_byte), ('BatteryLifePercent', ctypes.c_byte),
                        ('SystemStatusFlag', ctypes.c_byte), ('BatteryLifeTime', ctypes.c_ulong), ('BatteryFullLifeTime', ctypes.c_ulong)]
        s = SPS()
        if ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(s)):
            return {0: False, 1: True}.get(s.ACLineStatus)
    return None


def build_model():
    def block(cin, cout, k, stride=1, dilation=1):
        return nn.Sequential(nn.Conv1d(cin, cout, k, stride=stride, dilation=dilation, padding=dilation * (k // 2), bias=False),
                             nn.BatchNorm1d(cout), nn.ReLU(inplace=True))

    class CNN(nn.Module):
        def __init__(self):
            super().__init__()
            self.features = nn.Sequential(block(CHANNELS, 16, 7, 2), block(16, 32, 5, 2), block(32, 64, 5, 2), block(64, 64, 3, 1, 2))
            self.head = nn.Sequential(nn.Dropout(0.3), nn.Linear(128, CLASSES))

        def forward(self, x):
            z = self.features(x)
            return self.head(torch.cat([z.mean(-1), z.amax(-1)], 1))
    return CNN()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seconds', type=float, default=60, help='sustained-load duration')
    ap.add_argument('--threads', type=int, default=max(1, (os.cpu_count() or 2) // 2 - 1),
                    help='intra-op threads (default: physical cores - 1, assuming 2 threads per core)')
    a = ap.parse_args()
    torch.set_num_threads(a.threads)
    torch.manual_seed(0)

    print(f'Python {platform.python_version()} ({platform.architecture()[0]}), torch {torch.__version__}, '
          f'{platform.processor() or platform.machine()}')
    print(f'logical CPUs {os.cpu_count()}, torch threads {torch.get_num_threads()}, AC power: {on_ac_power()}')

    model = build_model()
    n_par = sum(p.numel() for p in model.parameters())
    opt = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-4)
    loss_fn = nn.CrossEntropyLoss()
    x = torch.randn(BATCH, CHANNELS, SAMPLES)
    y = torch.randint(0, CLASSES, (BATCH,))
    data_mb = N_WINDOWS * CHANNELS * SAMPLES * 4 / 2**20
    print(f'model parameters: {n_par:,}   full dataset in RAM (float32): {data_mb:.0f} MB')
    rss0, _ = rss_mb()

    def step():
        opt.zero_grad(set_to_none=True)
        loss_fn(model(x), y).backward()
        opt.step()

    model.train()
    for _ in range(5):                       # warm-up
        step()

    times = []
    t_end = time.perf_counter() + a.seconds
    while time.perf_counter() < t_end:
        t0 = time.perf_counter()
        step()
        times.append(time.perf_counter() - t0)
    n = len(times)
    k = max(1, n // 10)
    first, last = sorted(times[:k])[k // 2], sorted(times[-k:])[k // 2]
    med = sorted(times)[n // 2]
    throttle = last / first

    # single-window inference latency (relay decision)
    model.eval()
    x1 = x[:1]
    with torch.no_grad():
        for _ in range(20):
            model(x1)
        t0 = time.perf_counter()
        for _ in range(200):
            model(x1)
        infer_ms = (time.perf_counter() - t0) / 200 * 1e3

    rss1, peak = rss_mb()
    steps_epoch = int(N_WINDOWS * TRAIN_FRACTION / BATCH) + 1
    epoch_s = steps_epoch * med * 1.15        # +15 % for validation pass and data handling
    cv_h = epoch_s * EPOCHS * FOLDS * SEEDS / 3600

    print('\n--- results ---')
    print(f'training steps measured     : {n} over {a.seconds:.0f} s')
    print(f'step time (median)          : {med * 1e3:.1f} ms   (first 10 %: {first * 1e3:.1f} ms, last 10 %: {last * 1e3:.1f} ms)')
    print(f'sustained slowdown ratio    : {throttle:.2f}  (last / first)')
    print(f'single-window inference     : {infer_ms:.2f} ms  ({100 * infer_ms / DECISION_BUDGET_MS:.0f} % of the {DECISION_BUDGET_MS} ms budget)')
    print(f'process memory              : {rss1:.0f} MB now, {peak:.0f} MB peak (start {rss0:.0f} MB)')
    print(f'projected epoch time        : {epoch_s:.1f} s ({steps_epoch} steps)')
    print(f'projected full CV           : {cv_h:.1f} h  ({FOLDS} folds x {SEEDS} seeds x {EPOCHS} epochs)')

    verdict = []
    verdict.append(('step time', med < 0.25, 'median step < 250 ms'))
    verdict.append(('throttling', throttle < 1.25, 'slowdown ratio < 1.25'))
    verdict.append(('memory', peak + data_mb < 4096, 'peak process + dataset < 4 GB'))
    verdict.append(('inference', infer_ms < 0.5 * DECISION_BUDGET_MS, 'inference < 50 % of 8.35 ms'))
    verdict.append(('total time', cv_h < 12, 'full CV < 12 h (one overnight run)'))
    print('\n--- verdict ---')
    for name, ok, rule in verdict:
        print(f'{"PASS" if ok else "FAIL"}  {name:11s} {rule}')
    if on_ac_power() is False:
        print('NOTE  running on battery: plug in and repeat, timings on battery are not representative')


if __name__ == '__main__':
    main()
