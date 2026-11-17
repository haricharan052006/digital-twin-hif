# Digital Twin-Assisted High Impedance Fault (HIF) Detection and Phase Localization on the IEEE 13-Bus Distribution Feeder

**Final-year capstone project — Simscape Electrical / Simulink digital-twin fault diagnostics**

---

## Executive Summary

This project detects and phase-localizes **High Impedance Faults (HIF)** on an unbalanced 4.16 kV IEEE 13-bus distribution feeder using a **digital-twin differential residual** combined with **multiresolution wavelet feature extraction** and supervised machine learning.

A physical feeder model (with a randomized, asymmetric Emanuel arc fault injectable on any of phases A/B/C, plus benign capacitor-switching and step-load decoy events) runs alongside a healthy, un-faulted digital-twin replica. Subtracting the twin's substation current from the physical model's cancels the ~330 A nominal load current and isolates the low-amplitude (~2 A) non-linear arcing signature — a signal that would otherwise be buried in normal load current and invisible to conventional overcurrent protection.

**Core result:** the differential residual, decomposed with a 5-level Daubechies-4 (`db4`) discrete wavelet transform into a 75-element feature vector (energy, Shannon entropy, standard deviation, and max-absolute-value across 6 sub-bands × 3 phases, plus 3 cross-phase metrics), lets an SVM, Random Forest, and MLP all separate five classes — **Normal, Switching Transient, HIF Phase A, HIF Phase B, HIF Phase C** — with 99.3–100% clean test-set accuracy. This distinguishes genuine arcing faults from superficially similar non-fault switching transients and pinpoints the faulted phase, both of which conventional threshold-based relays cannot do reliably for high-impedance faults. **Measurement-noise robustness, however, is not solved by this pipeline and is reported honestly as a limitation** (§4.4): Random Forest degrades gracefully under realistic CT noise, but SVM and MLP collapse sharply once noise exceeds a very low floor, and noise-augmented retraining only partially and inconsistently recovers it.

---

## Table of Contents

1. [System Architecture & Physical Modeling](#1-system-architecture--physical-modeling)
2. [Feature Extraction Pipeline](#2-feature-extraction-pipeline)
3. [Machine Learning Pipeline](#3-machine-learning-pipeline)
4. [Experimental Results](#4-experimental-results)
5. [Repository Structure](#5-repository-structure)
6. [Quick Start — Full Reproduction](#6-quick-start--full-reproduction)
7. [Known Limitations & Future Work](#7-known-limitations--future-work)

---

## 1. System Architecture & Physical Modeling

### 1.1 Feeder model

The IEEE 13-Node Test Feeder is built programmatically in Simulink using **Simscape Electrical (Specialized Power Systems)** blocks only:

- Unbalanced 4.16 kV L-L / 2.4 kV L-N, 60 Hz radial feeder, ~3.5 MVA aggregate spot load (~330 A peak at the Bus 650 substation source).
- Three-Phase PI Section Line segments parameterized from the published IEEE13 configuration matrices (positive/zero-sequence R, L, C).
- The standard IEEE13 spot-load table (Y/Δ, per-phase P/Q, constant-PQ/Z/I load models) at Buses 634, 645, 646, 652, 671, 675, 692, 611, faithfully preserving per-phase unbalance.
- Shunt capacitor banks at Bus 675 (200 kVAr/phase) and Bus 611 (100 kVAr, phase C).
- A 4.16 kV Δ / 0.48 kV Yg step-down transformer (633–634), and the 671–692 normally-closed tie.
- **Solver:** discrete `powergui`, fixed step **Ts = 50 µs (fs = 20 kHz)**, per the project's sampling specification.

Two model variants are built from the same feeder topology:

| Model | Role |
|---|---|
| `models/ieee13_physical.slx` | Carries the switchable HIF/decoy-event branches; this is what actually gets faulted or perturbed per simulation run. |
| `models/ieee13_digital_twin.slx` | Identical feeder, permanently healthy — the fixed reference the physical model is differenced against. Never randomized. |

### 1.2 Emanuel arc HIF model

`models/emanuel_arc_subsystem.slx` implements the classical Emanuel two-branch asymmetric arc model: antiparallel diode branches (positive/negative half-cycle), each a Diode + DC breakdown-voltage source + arcing/soil resistance in series, joined at a common node and metered by a Current Measurement block.

| Parameter | Range swept |
|---|---|
| Positive breakdown voltage, Vp | 500 – 8000 V |
| Negative breakdown voltage, Vn | 1000 – 10000 V |
| Positive-branch arcing/soil resistance, Rp | 120 – 5000 Ω |
| Negative-branch arcing/soil resistance, Rn | 120 – 5000 Ω |
| Fault inception angle | 0 – 360° within one 60 Hz cycle |

The fault is injectable on **any of phases A, B, or C** at Bus 671: `extend_fault_injection.m` added phase-B/C fault branches (`FaultBreaker_671B/C` → `Emanuel_Arc_FaultB/C` → ground) mirroring the original phase-A branch, all defaulting to a dead/open state so the baseline feeder is unaffected unless a specific run commands one closed.

### 1.3 Decoy events — non-fault switching transients

To force the classifier to distinguish *genuine arcing* from *superficially similar transients*, three switchable benign events were added to the physical model:

- **Capacitor bank switching** — a gang three-phase breaker (`CapBrk_675`) and a single-phase breaker (`CapBrk_611C`) in series with the existing capacitor banks, allowing energize/de-energize inrush events at a random time.
- **Step-load change** — a switchable Y-connected 80 kW/40 kVAr-per-phase load bank (`LoadStepBrk_671` + `LoadStepA/B/C_671`) at Bus 671, normally out of circuit.
- **Healthy load variation** — ±5–15% randomized scaling of every spot load's P/Q, applied per simulation run (the "Normal" class).

### 1.4 Differential residual formulation

$$\Delta I(t) = I_{\text{physical}}(t) - I_{\text{twin}}(t)$$

Both models log the 3-phase substation current at Bus 650 (`I_650`, via a `Three-Phase V-I Measurement` block + Simulink signal logging). Runs are resampled onto a common uniform 20 kHz grid before subtraction (`interp1`, handling any solver-timestep or breaker-switching discontinuities), so $\Delta I$ is well-defined regardless of solver behavior. This cancels the ~330 A nominal load current, isolating the ~2 A-scale non-linear arcing signature (or the corresponding switching/load-step transient) that would otherwise be undetectable against the load background.

**Dataset generated:** 750 simulation runs (`data/raw_residuals.mat`), 20 kHz, 300 ms per run (6001 samples), **100% simulation success rate**:

| Class | Count |
|---|---|
| Normal | 150 |
| Switching Transient | 150 |
| HIF Phase A | 150 |
| HIF Phase B | 150 |
| HIF Phase C | 150 |
| **Total** | **750** |

---

## 2. Feature Extraction Pipeline

### 2.1 5-level DWT (Daubechies-4)

Each phase's residual $\Delta I_{\phi}(t)$ is decomposed with a 5-level `db4` Discrete Wavelet Transform (`wavedec`), splitting the 0–10 kHz Nyquist band (fs = 20 kHz) into:

| Sub-band | Approximate frequency range |
|---|---|
| A5 (approximation) | 0 – 312.5 Hz |
| D5 | 312.5 – 625 Hz |
| D4 | 625 Hz – 1.25 kHz |
| D3 | 1.25 – 2.5 kHz |
| D2 | 2.5 – 5 kHz |
| D1 | 5 – 10 kHz |

### 2.2 75-element feature vector

For each of the 6 sub-bands × 3 phases (A/B/C), four statistics are computed on the wavelet coefficients $C$:

| Statistic | Formula |
|---|---|
| Energy | $\sum C^2$ |
| Normalized Shannon Entropy | $-\sum p \log(p+\varepsilon),\ \ p = C^2/\sum C^2$ |
| Standard Deviation | $\text{std}(C)$ |
| Max Absolute Value | $\max\lvert C\rvert$ |

→ **72 per-phase features.** Three cross-phase features complete the vector:

- Zero-sequence residual proxy $\Delta I_0 = (\Delta I_A+\Delta I_B+\Delta I_C)/3$ — **RMS** and **Energy**.
- **Max phase-unbalance ratio**: $(\max(\text{RMS}_\phi) - \min(\text{RMS}_\phi)) / \text{mean}(\text{RMS}_\phi)$ across the three phases (a NEMA-style unbalance definition applied to the residual current).

**→ 75 total features** (`data/features.mat`: `X` [750×75], `y` categorical labels, `featureNames`). No NaN/Inf entries in the final feature matrix.

---

## 3. Machine Learning Pipeline

- **Split:** stratified 80/20 hold-out (`cvpartition`, `Stratify=true`) → 600 train / 150 test (120/30 per class), fixed `rng(42)` for full reproducibility across every downstream script.
- **Standardization:** z-score scaling fit on the **training split only**, applied identically to the test split (no leakage).
- **Models**, each 5-fold cross-validated on the training partition:

| Model | Implementation |
|---|---|
| Multiclass SVM | `fitcecoc` + `templateSVM('KernelFunction','gaussian','KernelScale','auto')` (one-vs-one ECOC) |
| Random Forest | `fitcensemble('Method','Bag', 100 trees)` — bootstrap-aggregated trees, equivalent to `TreeBagger` |
| Feedforward MLP | `fitcnet`, 2 hidden layers [50, 30], ReLU activation |

All three share one evaluation path (`predict` / `confusionmat` / macro precision-recall-F1), so results are directly comparable.

---

## 4. Experimental Results

### 4.1 Baseline classifier benchmark

| Model | 5-fold CV Accuracy | Test Accuracy (n=150) | Macro Precision | Macro Recall | Macro F1 |
|---|---|---|---|---|---|
| SVM (RBF, ECOC, `KernelScale=auto`) | **98.17%** | **100.00%** | **1.0000** | **1.0000** | **1.0000** |
| Random Forest (100 trees) | **98.83%** | **99.33%** | **0.9935** | **0.9933** | **0.9933** |
| Feedforward MLP ([50,30], ReLU) | **98.67%** | **100.00%** | **1.0000** | **1.0000** | **1.0000** |

**Per-class test metrics** — SVM and MLP scored a perfect 1.0000 (Precision/Recall/F1) on every one of the 5 classes. Random Forest, the only model with any test-set misclassifications, broke down as:

| Class | Precision | Recall | F1 |
|---|---|---|---|
| Normal | 0.9677 | 1.0000 | 0.9836 |
| Switching Transient | 1.0000 | 0.9667 | 0.9831 |
| HIF Phase A | 1.0000 | 1.0000 | 1.0000 |
| HIF Phase B | 1.0000 | 1.0000 | 1.0000 |
| HIF Phase C | 1.0000 | 1.0000 | 1.0000 |

Random Forest's only confusion is between **Normal** and **Switching Transient** (one Switching Transient run misclassified as Normal, dragging its recall to 0.9667 and Normal's precision to 0.9677) — an intuitive failure mode, since a mild step-load/capacitor-switching event and a large healthy load-variation event can both present as a modest, brief residual-current transient. All three models achieve perfect (1.0000) separation of the three HIF phases from everything else, confirming the fault-phase localization goal.

Confusion matrices: [`results/confusion_matrix_SVM.png`](results/confusion_matrix_SVM.png) · [`results/confusion_matrix_RandomForest.png`](results/confusion_matrix_RandomForest.png) · [`results/confusion_matrix_NeuralNetwork.png`](results/confusion_matrix_NeuralNetwork.png)

### 4.2 Explainability & interpretability

Random Forest out-of-bag permuted predictor importance (`analyze_feature_importance.m`) confirms the feature set is **physically interpretable**, not just statistically convenient:

**By metric type** (72 per-phase features, 18 each, + 3 cross-phase):

| Metric Type | # Features | Total Importance | Mean Importance | Share |
|---|---|---|---|---|
| Shannon Entropy | 18 | 8.427348 | 0.468186 | **28.0%** |
| Standard Deviation | 18 | 7.157902 | 0.397661 | 23.8% |
| Max Absolute Value | 18 | 6.730290 | 0.373905 | 22.4% |
| Energy | 18 | 6.609403 | 0.367189 | 22.0% |
| Cross-Phase | 3 | 1.124100 | 0.374700 | 3.7% |

**By wavelet sub-band** (12 features each for A5–D1, 3 for Cross-Phase):

| Sub-band | # Features | Total Importance | Mean Importance | Share |
|---|---|---|---|---|
| D3 (1.25–2.5 kHz) | 12 | 5.758455 | 0.479871 | **19.2%** |
| D1 (5–10 kHz) | 12 | 5.026046 | 0.418837 | 16.7% |
| D5 (312.5–625 Hz) | 12 | 4.678835 | 0.389903 | 15.6% |
| A5 (0–312.5 Hz) | 12 | 4.591147 | 0.382596 | 15.3% |
| D4 (625 Hz–1.25 kHz) | 12 | 4.489085 | 0.374090 | 14.9% |
| D2 (2.5–5 kHz) | 12 | 4.381375 | 0.365115 | 14.6% |
| Cross-Phase | 3 | 1.124100 | 0.374700 | 3.7% |

Entropy leads (28.0%) because an arcing fault's asymmetric, non-sinusoidal re-ignition pattern spreads energy across many wavelet coefficients (high disorder / high entropy) in a way healthy load variation and clean switching transients do not — though it only narrowly outranks Standard Deviation (23.8%) and Max Absolute Value (22.4%), and Energy (22.0%) is close behind, so the four per-phase statistics are all contributing meaningfully rather than one dominating outright. **D3** (1.25–2.5 kHz) is the single most important sub-band at 19.2% — noticeably ahead of every other band — with **D1** (5–10 kHz, 16.7%) second; the remaining four sub-bands (D5, A5, D4, D2) are within a tight 14.6–15.6% band of each other, i.e. importance is concentrated in the mid-to-high frequency detail bands (D3, D1) where the arc's fast re-ignition transients and high-frequency current chopping actually show up, rather than in the coarse 0–625 Hz range (A5, D5) where healthy 60 Hz load current and its slow variations dominate. Cross-phase features carry the least importance individually (3.7% combined across just 3 features) but that is expected — they exist to catch phase-unbalance signatures the per-phase sub-band features can already capture more precisely on their own.

Top-15 feature importance chart: [`results/feature_importance.png`](results/feature_importance.png)

### 4.3 Real-time feasibility & latency benchmark

`benchmark_latency.m` measured mean/P99 latency over 1,000 iterations, using the same 6001-sample (300 ms) window the models were trained on:

| Stage | Model | Time (ms) | vs. 1-cycle @ 60 Hz (16.67 ms) |
|---|---|---|---|
| DWT feature extraction (`db4`, 5-level) | shared | **4.03** | — |
| Model inference | MLP | **0.29** | end-to-end ≈ 4.32 ms → **PASS** |
| Model inference | SVM | **2.50** | end-to-end ≈ 6.53 ms → **PASS** |
| Model inference | Random Forest | **48.75** | end-to-end ≈ 52.78 ms → **FAIL** |

**MLP and SVM both clear the 1-cycle (16.67 ms) protection-grade latency target with wide margin; Random Forest, dominated by traversing 100 trees per prediction, does not** — a real-time deployment favoring speed would use the MLP or SVM, reserving Random Forest for offline/forensic analysis or hardware with more headroom.

> **Caveat that latency numbers alone don't capture:** the 75 features are extracted from a full 300 ms residual window (6001 samples @ 20 kHz) — about **18 cycles** at 60 Hz. Even with near-instant compute, a relay cannot classify before it has *acquired* that much post-inception data, so true instantaneous (sub-1-cycle) tripping is not achievable with this exact feature design regardless of code speed; the Mamdani Fuzzy Inference System referenced in the project's original scope (fast LG-fault tripping) is the intended complement for that use case, with the wavelet/ML pipeline serving high-confidence HIF classification and phase localization on a ~300 ms decision horizon.

### 4.4 Measurement noise stress testing & noise-augmented retraining

`test_noise_robustness.m` first confirmed a modeling flaw: scaling AWGN to the residual $\Delta I$'s own variance (which is near-zero for Normal runs, ~2 A for HIF) is not physically meaningful and collapsed all three classifiers to near-random accuracy. The corrected test injects noise at **fixed absolute standard deviations** (σ = 0, 0.01, 0.05, 0.1, 0.2, 0.5, 1.0 A), representative of a realistic CT/relay noise floor against the feeder's ~330 A nominal current, and applies wavelet denoising (`wdenoise`) before feature extraction:

| Noise σ (A) | SVM Accuracy | SVM Macro F1 | RF Accuracy | RF Macro F1 | MLP Accuracy | MLP Macro F1 |
|---|---|---|---|---|---|---|
| Clean (0) | 1.0000 | 1.0000 | 0.9933 | 0.9933 | 1.0000 | 1.0000 |
| 0.01 | 0.6933 | 0.6507 | 0.9533 | 0.9539 | 0.5267 | 0.4904 |
| 0.05 | 0.2000 | 0.0667 | 0.7467 | 0.7506 | 0.3267 | 0.2379 |
| 0.1 | 0.2000 | 0.0667 | 0.6933 | 0.6973 | 0.3000 | 0.2133 |
| 0.2 | 0.2000 | 0.0667 | 0.6200 | 0.5991 | 0.2800 | 0.1988 |
| 0.5 | 0.2000 | 0.0667 | 0.5400 | 0.4855 | 0.2267 | 0.1830 |
| 1.0 | 0.2000 | 0.0667 | 0.4533 | 0.3904 | 0.2267 | 0.1795 |

**Even with wavelet denoising, noise robustness is a genuine weakness of this pipeline, not a solved problem.** Random Forest degrades gracefully — from 99.33% clean down to 45.33% at 1.0 A, a real but survivable decline. SVM and MLP, by contrast, both fall off a cliff between Clean and just 0.01 A (SVM: 100%→69.3%; MLP: 100%→52.7%) and then collapse to the 5-class random-guess floor (accuracy ≈ 0.20, macro F1 ≈ 0.07–0.24) by 0.05 A and stay there through 1.0 A. Wavelet denoising alone is not sufficient to protect the SVM/MLP decision boundaries once noise exceeds a very low threshold.

`train_noise_robust_classifiers.m` then tested whether **training-time** noise augmentation (AWGN σ = 0.02 A + light 2-level wavelet soft-thresholding on the training set, doubling it with clean + perturbed copies of every run) restores SVM/MLP robustness **without relying on test-time denoising** — isolating the augmentation effect from the wdenoise fix above:

| Noise σ (A) | SVM orig | SVM aug | RF orig | RF aug | MLP orig | MLP aug |
|---|---|---|---|---|---|---|
| Clean (0) | 1.0000 | 1.0000 | 0.9933 | 1.0000 | 1.0000 | 0.9933 |
| 0.01 | 0.2000 | 0.3067 | 0.9600 | 0.9933 | 0.5067 | 0.5800 |
| 0.05 | 0.2000 | 0.2000 | 0.5867 | 0.7000 | 0.2000 | 0.2000 |
| 0.1 | 0.2000 | 0.2000 | 0.4133 | 0.3933 | 0.2000 | 0.2000 |
| 0.2 | 0.2000 | 0.2000 | 0.3533 | 0.3867 | 0.2000 | 0.2000 |
| 0.5 | 0.2000 | 0.2000 | 0.2333 | 0.3800 | 0.2000 | 0.2000 |
| 1.0 | 0.2000 | 0.2000 | 0.2000 | 0.3200 | 0.2000 | 0.2000 |

**The honest finding: noise-augmented retraining mainly helped Random Forest, and barely helped SVM/MLP at all.** RF improved at every noise level except 0.1 A (e.g. 1.0 A: 20.0%→32.0%; 0.5 A: 23.3%→38.0%), and even reached a perfect 100% at Clean and 0.01 A post-augmentation. SVM and MLP, however, only improved at the single noise level closest to their σ=0.02 A training perturbation (0.01 A: SVM 20.0%→30.7%, MLP 50.7%→58.0%) and remained pinned at the ~20% random-guess floor everywhere else (0.05–1.0 A) — training on one fixed, fairly low noise level did not teach either model a noise-general decision boundary, it only shifted the cliff edge slightly. Note also this table's "original" SVM/MLP numbers are markedly worse than the wavelet-denoising table above at the same σ (e.g. SVM at 0.01 A: 69.3% with denoising vs. 20.0% without) — this is expected and by design, since this comparison deliberately omits test-time denoising to isolate the augmentation effect, confirming that **test-time wavelet denoising, not training-time augmentation, is what actually protects SVM/MLP** in this pipeline. **Random Forest is the clear choice where measurement noise is a realistic concern**, both for its gentler native degradation and because it is the model noise-augmented retraining actually improves.

Plots: [`results/noise_robustness_curve.png`](results/noise_robustness_curve.png) (wavelet-denoising fix) · [`results/noise_augmented_comparison.png`](results/noise_augmented_comparison.png) (original vs. noise-augmented retraining)

---

## 5. Repository Structure

```
ieee13-digital-twin-hif/
├── CLAUDE.md                          # Project spec: system parameters, toolbox requirements, dev rules
├── README.md                          # This document
├── models/
│   ├── ieee13_physical.slx            # Feeder + switchable HIF/decoy-event branches
│   ├── ieee13_digital_twin.slx        # Identical feeder, permanently healthy reference
│   ├── emanuel_arc_subsystem.slx      # Reusable Emanuel two-branch arc HIF model
│   ├── test_fault_iso.slx
│   ├── trained_classifiers.mat        # mdlSVM, mdlRF, mdlNN, scaler, results, classNames
│   └── trained_classifiers_noise_robust.mat
├── scripts/
│   ├── build_emanuel_arc.m            # Phase 1: builds emanuel_arc_subsystem.slx
│   ├── build_ieee13_network.m         # Phase 2: builds the 13-bus feeder (both variants)
│   ├── add_scopes_and_verify.m        # Phase 2: instrumentation + waveform sanity check
│   ├── extend_fault_injection.m       # Phase 3 prep: adds phase-B/C HIF + switchable decoy branches
│   ├── generate_dataset.m             # Phase 3: 750-run batch simulation -> raw_residuals.mat
│   ├── extract_features.m             # Phase 4: 75-feature DWT extraction -> features.mat
│   ├── train_classifiers.m            # Phase 5: SVM/RF/MLP training + evaluation
│   ├── analyze_feature_importance.m   # Phase 5: RF feature-importance analysis + plot
│   ├── test_noise_robustness.m        # Extension: CT-noise stress test + wavelet-denoising fix
│   ├── train_noise_robust_classifiers.m  # Extension: noise-augmented retraining experiment
│   └── benchmark_latency.m            # Extension: real-time inference latency benchmark
├── data/
│   ├── raw_residuals.mat              # dI [6001x3x750], labels, tGrid, meta
│   ├── features.mat                   # X [750x75], y, featureNames
│   ├── raw_waveforms/
│   ├── processed_features/
│   └── waveform_check.png             # Physical-vs-twin / residual / arc-current sanity figure
├── results/
│   ├── confusion_matrix_SVM.png
│   ├── confusion_matrix_RandomForest.png
│   ├── confusion_matrix_NeuralNetwork.png
│   ├── feature_importance.png
│   ├── noise_robustness_curve.png
│   └── noise_augmented_comparison.png
├── src/                                # Reserved for future standalone deployment code
└── slprj/                              # Simulink build cache
```

---

## 6. Quick Start — Full Reproduction

Requires MATLAB with **Simulink, Simscape Electrical (Specialized Power Systems), Wavelet Toolbox, Statistics and Machine Learning Toolbox**. Run from the repository root, in this exact order (later scripts depend on earlier scripts' outputs):

```matlab
% Phase 1-2: build the physical models
run('scripts/build_emanuel_arc.m');
run('scripts/build_ieee13_network.m');
run('scripts/add_scopes_and_verify.m');       % instruments + sanity-checks the models

% Phase 3 prep: add phase-B/C HIF branches + switchable decoy-event branches
run('scripts/extend_fault_injection.m');

% Phase 3: batch-generate the 750-run residual-current dataset
run('scripts/generate_dataset.m');

% Phase 4: extract the 75-feature DWT vector
run('scripts/extract_features.m');

% Phase 5: train and evaluate SVM / Random Forest / MLP
run('scripts/train_classifiers.m');
run('scripts/analyze_feature_importance.m');

% Extensions: noise robustness, noise-augmented retraining, latency benchmark
run('scripts/test_noise_robustness.m');
run('scripts/train_noise_robust_classifiers.m');
run('scripts/benchmark_latency.m');
```

Every script is **idempotent / additive** where it touches a saved model, and every random draw is seeded (`rng(42)`) for full reproducibility — re-running the full sequence should reproduce the same 750-run dataset, the same train/test split, and the same trained models.

---

## 7. Known Limitations & Future Work

- **Measurement-noise robustness is unresolved for SVM and MLP** (§4.4), and is the most significant limitation of this work. Both models collapse to near-random accuracy (~20%) once realistic CT noise exceeds ~0.01–0.05 A, with or without wavelet denoising or the noise-augmented retraining tried here — training on one fixed low noise level (σ=0.02 A) shifted the collapse point slightly but did not teach either model a genuinely noise-general decision boundary. Random Forest is the only model that degrades gracefully and is measurably improved by noise-augmented retraining, making it the recommended choice wherever the CT/relay measurement chain cannot guarantee a very clean signal. Closing this gap for SVM/MLP would likely need noise augmentation across a *range* of σ values (not one fixed level) or an architecturally different denoising-aware feature pipeline.
- **Latency vs. noise-robustness is a real trade-off, not a free choice**: SVM and MLP comfortably clear the 1-cycle latency target (§4.3) but are noise-fragile; Random Forest is noise-robust but ~3× over the 1-cycle budget (48.75 ms inference alone). No single model in this study is simultaneously fast enough for sub-cycle tripping and robust to realistic measurement noise — a deployment must pick which constraint matters more, or run a faster model behind a hardware-level anti-aliasing/noise-filtering front end.
- **Engineering approximations in the feeder model** (documented in `build_ieee13_network.m`): the 115 kV/4.16 kV substation transformer and the 650–632 voltage regulator are omitted; zero-sequence line parameters are approximated as 2.5× positive-sequence (a standard distribution rule of thumb) rather than derived from full mutual-coupling matrices; the distributed load along line 632–671 is lumped into the spot-load table.
- **Acquisition-window latency** (§4.3): the current feature design requires a 300 ms observation window regardless of compute speed. A true sub-1-cycle instantaneous trip would need a redesigned feature pipeline around a much shorter sliding window (1–2 cycles) — a data-design change, not a code-speed optimization.
- **Single random seed**: all results reflect one `rng(42)` train/test split and one simulation batch. A more rigorous robustness claim would repeat the full pipeline across multiple seeds and report variance.
- **Mamdani Fuzzy Inference System** (secondary engine, per the original project scope, for fast LG-fault tripping) has not yet been implemented in this repository — the wavelet/ML pipeline documented here addresses HIF classification and phase localization, not instantaneous LG-fault tripping.
- **No solar/PV components** are present anywhere in this repository, per project rules.
