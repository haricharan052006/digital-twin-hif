# Project Context: High Impedance Fault (HIF) Detection via Digital Twin

## Technical Domain & Stack
- **System**: Unbalanced 4.16 kV IEEE 13-Bus Distribution Network
- **Toolbox Requirements**: MATLAB, Simulink, Simscape Electrical, Wavelet Toolbox, Statistics and Machine Learning Toolbox, Fuzzy Logic Toolbox
- **Execution Engine**: Claude Code CLI running programmatic MATLAB/Simulink scripts

## System Parameters
- **Sampling Frequency (fs)**: 20 kHz (Ts = 50e-6 s)
- **Nominal Line Voltage**: 4.16 kV L-L (2.4 kV L-N)
- **Emanuel Arc Model Ranges**:
  - Positive Arc Breakdown Voltage (Vp): 500 V to 8000 V
  - Negative Arc Breakdown Voltage (Vn): 1000 V to 10000 V
  - Arcing Soil Resistances (Rp, Rn): 120 Ohm to 5000 Ohm

## Signal Processing & Feature Extraction
- **Wavelet Transform**: Discrete Wavelet Transform (DWT)
- **Mother Wavelet**: Daubechies 4 ('db4')
- **Decomposition Levels**: 5 Levels
- **Extracted Features**: Phase energy (E1 to E5), Mean, Standard Deviation, Skewness, Kurtosis

## Classifiers & Target Performance
- **Primary Engine**: Random Forest Classifier for HIF vs Transient Events (Target Accuracy: >= 99.41%)
- **Secondary Engine**: Mamdani Fuzzy Inference System (FIS) for fast Line-to-Ground (LG) fault tripping

## Development Rules
1. All Simulink blocks must come from Simscape / Electrical / Specialized Power Systems.
2. Always ensure a powergui block is configured in continuous mode or discrete mode at Ts = 50e-6 s.
3. Never include solar/PV components in this repository.
