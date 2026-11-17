"""End-to-end 1D-CNN HIF relay classifier and its input scalings.

The base network is the ~26k-parameter design benchmarked by
tools/cnn_hw_check.py: four Conv1d-BatchNorm-ReLU blocks (strides 2, 2, 2, 1
with dilation 2 in the last) on the raw 3-phase residual window [3 x 667],
then global mean and max pooling concatenated (128) -> dropout -> linear (5
classes). No wavelet or handcrafted features. Its receptive field is only 63
samples, so arch='wide' is the receptive-field ablation (see HifCNN).

Input scalings (the residual spans ~0.4 A weak arcs to ~660 A capacitor
switching transients, about 1000:1):
    slog  sign(x) * log1p(|x| / X0), X0 = 0.1 A - linear below ~0.1 A,
          logarithmic above, so micro-arc waveshape and large decoy
          transients both stay inside a few units
    ref   x / x_ref, x_ref = 99th percentile of |x| over the training windows
          (one global reference, fit on training data only) - linear
"""
import numpy as np
import torch
import torch.nn as nn

X0_SLOG = 0.1          # A, knee of the signed-log scaling
CHANNELS, CLASSES = 3, 5


class Scaling:
    def __init__(self, kind, ref=None):
        assert kind in ('slog', 'ref')
        self.kind, self.ref = kind, ref

    @classmethod
    def fit(cls, kind, windows):
        if kind == 'slog':
            return cls(kind)
        return cls(kind, float(np.percentile(np.abs(windows), 99)))

    def __call__(self, x):
        x = np.asarray(x, dtype=np.float32)
        if self.kind == 'slog':
            return np.sign(x) * np.log1p(np.abs(x) / X0_SLOG)
        return x / self.ref

    def state(self):
        return {'kind': self.kind, 'ref': self.ref, 'x0': X0_SLOG}


def _block(cin, cout, k, stride=1, dilation=1):
    return nn.Sequential(nn.Conv1d(cin, cout, k, stride=stride, dilation=dilation,
                                   padding=dilation * (k // 2), bias=False),
                         nn.BatchNorm1d(cout), nn.ReLU(inplace=True))


class HifCNN(nn.Module):
    """arch 'base': the cnn_hw_check.py design, receptive field 63 samples
    (3.2 ms, 0.19 cycle). arch 'wide': receptive-field ablation at about the
    same capacity (~31k vs ~26k parameters) - seven blocks, four stride-2
    stages, then dilations 2 / 4 / 8, receptive field 703 samples (2.1
    cycles), i.e. the whole 667-sample window including both half-cycles."""

    def __init__(self, arch='base'):
        super().__init__()
        self.arch = arch
        if arch == 'base':
            blocks = [_block(CHANNELS, 16, 7, 2), _block(16, 32, 5, 2),
                      _block(32, 64, 5, 2), _block(64, 64, 3, 1, 2)]
        elif arch == 'wide':
            blocks = [_block(CHANNELS, 16, 7, 2), _block(16, 32, 5, 2), _block(32, 32, 5, 2),
                      _block(32, 32, 5, 2), _block(32, 32, 5, 1, 2), _block(32, 32, 5, 1, 4),
                      _block(32, 64, 3, 1, 8)]
        else:
            raise ValueError(f'unknown arch {arch!r}')
        self.features = nn.Sequential(*blocks)
        self.head = nn.Sequential(nn.Dropout(0.3), nn.Linear(128, CLASSES))

    def forward(self, x):
        z = self.features(x)
        return self.head(torch.cat([z.mean(-1), z.amax(-1)], 1))


def receptive_field(model):
    """Receptive field of the convolution stack in samples."""
    rf, jump = 1, 1
    for blk in model.features:
        conv = blk[0]
        rf += conv.dilation[0] * (conv.kernel_size[0] - 1) * jump
        jump *= conv.stride[0]
    return rf


def load_checkpoint(path):
    """(model, scaling, checkpoint) of a models/dl/cnn_*.pt file."""
    ck = torch.load(path, weights_only=False)
    model = HifCNN(ck.get('arch', 'base'))
    model.load_state_dict(ck['state_dict'])
    model.eval()
    s = ck['scaling']
    return model, Scaling(s['kind'], s['ref']), ck


@torch.no_grad()
def predict_proba(model, scaling, windows, batch=1024):
    """Class probabilities [N x 5] for raw windows [N x 3 x W] (A)."""
    model.eval()
    out = []
    for i in range(0, len(windows), batch):
        x = torch.from_numpy(scaling(windows[i:i + batch]))
        out.append(torch.softmax(model(x), 1).numpy())
    return np.concatenate(out)
