# Real-Time Respiratory Phase Classification

Source code, data processing tools and experimental materials developed for the master's thesis:

**Modeling the Respiratory System with Artificial Neural Networks**

Author: **Jakub Kabat**
Gdańsk University of Technology

## Overview

This project implements a complete system for real-time recognition of respiratory cycle phases from a strain-sensing belt signal.

The system classifies four respiratory phases:

- inhalation,
- exhalation,
- post-inhalation retention,
- post-exhalation retention.

A lightweight one-dimensional convolutional neural network processes consecutive signal windows. The model output is additionally processed using sequential constraints describing the allowable order of respiratory phases.

The trained model is exported to ONNX and executed directly on an Android mobile device using ONNX Runtime. The mobile application was developed in Flutter, while the model training and evaluation pipeline was implemented in Python.

All real-time processing is performed locally on the mobile device and does not require a remote server.

---

## Quick Start

### Requirements

| Component | Version |
|---|---|
| Python | 3.13 |
| PyTorch | 2.11.0 |
| ONNX | 1.21.0 |
| Flutter | see `mobile_app/pubspec.yaml` |
| Target platform | Android 16 (tested on Samsung Galaxy S24 Ultra) |

Python dependencies:

```bash
pip install -r requirements.txt
```

### Train the model

```bash
cd training
python train_model.py            # ~36 s on CPU
python export_onnx.py            # writes models/breathing_model.onnx
```

### Reproduce a single experiment

```bash
cd analysis/experiments
python ablacja_postprocessingu.py ../../data/recordings/pomiar2.txt \
                                  ../../models/breathing_model.pt
```

See [`docs/experiments.md`](docs/experiments.md) for the full mapping between
scripts and the tables and figures presented in the thesis.

### Build the mobile application

```bash
cd mobile_app
flutter pub get
flutter run --release
```

The application also provides a test mode that replays a recorded signal file,
so the full processing pipeline can be exercised without the physical belt.

---

## System Architecture

The system consists of three main parts:

1. **Measurement module**
   - strain-sensing respiratory belt,
   - ESP32 microcontroller,
   - Bluetooth Low Energy communication.

2. **Mobile application**
   - BLE data acquisition,
   - packet integrity verification,
   - signal calibration and preprocessing,
   - neural network inference,
   - sequential post-processing,
   - respiratory phase visualization,
   - respiratory cycle and respiratory rate estimation,
   - session storage and export.

3. **Python training and evaluation pipeline**
   - dataset preparation,
   - automatic and manual labeling,
   - generation of training windows,
   - model training,
   - ONNX export,
   - classification evaluation,
   - experimental analysis.

The mechanical construction of the strain-sensing belt and its measurement electronics were developed as part of a parallel master's thesis. This project focuses primarily on the software, signal processing, machine learning and mobile application components.

---

## Respiratory Phase Classification

The classifier is based on a lightweight 1D convolutional neural network referred to in the project as `BreathingCNN`.

The default model uses an input window of 30 consecutive signal samples, corresponding to approximately 3 seconds of respiratory signal.

The network consists of:

- four one-dimensional convolutional layers,
- batch normalization,
- ReLU activation,
- max pooling,
- dropout,
- global average pooling,
- fully connected classification layers.

The model contains **28,708 trainable parameters**.

The network produces four output scores corresponding to the respiratory phases:

| Index | Phase |
|---:|---|
| 0 | Inhalation |
| 1 | Exhalation |
| 2 | Post-inhalation retention |
| 3 | Post-exhalation retention |

---

## Sequential Post-Processing

Each signal window is initially classified independently.

To improve temporal consistency, the classifier output is processed using a Viterbi-based decoder with a predefined transition matrix.

The transition matrix does not contain transition probabilities learned from the dataset. Instead, it defines which transitions between respiratory phases are allowed or forbidden.

A minimum phase duration filter is additionally applied to suppress very short phase detections.

The current implementation contains several limitations related to real-time sequential processing. These are described in the thesis and were identified during end-to-end validation.

---

## Respiratory Cycle Detection

Respiratory rate is derived from the classifier output rather than from the raw signal. Counting every transition into the inhalation phase, however, overestimates the number of breaths: an inhalation performed in two movements separated by a shallow signal dip is counted twice. This follows directly from the transition matrix, which forbids a direct return from post-inhalation retention to inhalation, so the pause must be closed by another phase.

The system therefore accepts a transition into inhalation as the start of a new cycle only when it occurs at a stretch level close to that of the previously accepted cycle starts. The rule is implemented in a single shared module (`cycle_detector.dart`) used by the real-time rate display, the chart markers and the stored session statistics, which keeps all three consistent.

---

## Signal Processing

The raw sensor signal depends on belt placement, body shape and sensor characteristics and therefore requires calibration before being used by the classifier.

The processing pipeline includes:

- conversion of raw sensor values to a normalized stretch scale,
- determination of the operating range,
- resting-level calibration,
- compensation for slow baseline drift,
- preparation of fixed-length classifier input windows.

Two approaches to baseline handling were investigated:

- drift compensation based on local minimum detection,
- rolling calibration used during continuous measurements.

Only one of them is active at a time, since both correct the same quantity.

The signal level is intentionally preserved because it provides information required to distinguish post-inhalation and post-exhalation retention.

---

## Bluetooth Low Energy

The measurement module communicates with the mobile application using Bluetooth Low Energy.

The BLE service contains separate characteristics for:

- measurement data,
- control messages,
- calibration parameters.

The application implements packet sequence numbering, checksum verification, retransmission requests, connection quality monitoring and automatic reconnection.

**Note:** the measurement module used in the experiments reported in the thesis transmits raw sensor values without sequence numbers or checksums. The integrity mechanisms listed above are present in the application but remain inactive with that module, and packet-loss statistics are therefore not reported in the thesis.

---

## Mobile Application

The mobile application was implemented in **Flutter**.

Main functions include:

- BLE device discovery and connection,
- respiratory signal acquisition,
- calibration,
- ONNX Runtime inference,
- real-time respiratory phase visualization,
- respiratory cycle detection,
- respiratory rate estimation,
- session recording,
- result export,
- test mode using previously recorded signals.

The neural network is executed locally on the phone. No cloud inference is required.

---

## Model Training

The model training pipeline was implemented using Python and PyTorch.

The default training configuration includes:

- input window: 30 samples,
- training window stride: 3 samples,
- batch size: 256,
- epochs: 40,
- optimizer: Adam,
- initial learning rate: 0.001,
- weight decay: 0.0001,
- cross-entropy loss,
- cosine learning-rate schedule.

The training dataset is imbalanced, particularly for post-inhalation retention.

To reduce the effect of class imbalance, training examples are sampled with replacement using class-dependent weights inversely proportional to class frequency.

---

## Dataset and Labels

The original training material comes from a publicly available dataset of
respiratory recordings published by Szymański et al. (see *References* below).
It contains several breathing patterns, including normal, shallow, slow and
fast breathing, post-inhalation and post-exhalation breath holds, and coughing.

The labels distributed with that dataset were not used. All recordings were
labeled again with the threshold-based method implemented in this repository,
which is based on the derivative of a smoothed respiratory signal and on the
absolute signal level, so that the training data and the recordings made for
evaluation would be labeled by the same procedure.

**The original dataset is not redistributed here.** It is available from the
repository linked below, under its own licence. This repository contains the
scripts needed to convert it into the format used for training.

Recordings made by the author for the purposes of the thesis — including the
manually annotated training material, the control recording and the recordings
used for computational and end-to-end measurements — are included in `data/`.

---

## Evaluation

The system was evaluated at both model and complete-system level.

The experiments include:

- computational performance on a mobile device,
- influence of sequential post-processing,
- comparison with the threshold-based method,
- influence of classifier input window length,
- influence of manually annotated training data,
- respiratory rate estimation,
- end-to-end validation of the mobile processing pipeline.

Because the respiratory phase classes are imbalanced, **macro-F1** is used as the primary classification metric.

Manually annotated recording segments were used as references independent of both the neural network and the threshold-based labeling method.

---

## Selected Results

The implemented CNN contains **28,708 parameters**, and the exported ONNX model occupies **113 kB** (116,153 bytes).

On the tested Android device, the median processing time for one incoming sample was **0.7 ms**, compared with a **100 ms** sampling interval — a margin of more than two orders of magnitude.

On a manually annotated reference segment, the neural-network-based approach reached **macro-F1 = 0.818**, compared with **0.755** for the threshold-based method, with the largest advantage on post-inhalation retention.

Extending the training dataset with 20 minutes of manually annotated recordings of breathing patterns that are difficult for the threshold method increased macro-F1 on a separate control recording from **0.828 to 0.876**. Most of that gain comes from the first five minutes of added material.

For respiratory rate estimation, counting every transition into inhalation overestimated the rate by **1.907 breaths/min**. The cycle detection criterion used in the system reduced the mean error to **0.395 breaths/min** on the same control recording.

These results should be interpreted together with the limitations described below.

---

## Known Limitations

This repository contains a research prototype rather than a production or medical system.

The main limitations identified during the thesis evaluation include:

- limited amount of training and manually annotated data,
- evaluation involving a limited number of measurement sessions and users,
- class imbalance, particularly for post-inhalation retention,
- differences between the signal characteristics of the original training recordings and later measurements,
- approximately 1.5 s structural delay caused by the context window,
- differences between the Python and mobile implementations of some processing steps,
- limitations of the current state handling in sequential decoding,
- gradual memory growth observed during longer mobile application sessions.

The system was not validated as a medical device.

Its outputs should not be interpreted as medical diagnoses.

---

## Repository Contents

```text
.
├── mobile_app/              # Flutter mobile application
├── training/                # CNN training pipeline and ONNX export
├── analysis/
│   ├── prepare/             # recording preparation and manual labeling tools
│   ├── experiments/         # scripts producing the thesis results
│   └── figures/             # figure generation scripts
├── data/
│   ├── recordings/          # respiratory signal recordings
│   ├── labels/              # manual phase and cycle annotations
│   └── logs/                # inference timing and memory logs
├── models/                  # trained and exported models
├── docs/
│   └── experiments.md       # mapping between scripts and thesis results
├── LICENSE
└── README.md
```

Code comments and script output are partly in Polish, since the thesis is written in Polish. Module and function names are in English.

---

## References

The training dataset used in this work:

> Szymański, J., Szefler, M., Karski, K., Krawczak, F., Jankowski, D.
> *Parallel datasets for classification of respiratory rhythm phases.*
> Scientific Data 12, 346 (2025). https://doi.org/10.1038/s41597-025-04625-5

Dataset repository: https://doi.org/10.34808/ray2-4g53

If you use this code, please cite the thesis:

> Kabat, J. *Modeling the Respiratory System with Artificial Neural Networks.*
> Master's thesis, Gdańsk University of Technology, 2026.

---

## Licence

Code is released under the MIT Licence. Recordings made by the author are
released under CC BY 4.0. See [`LICENSE`](LICENSE) for details.

The externally sourced dataset described above is **not** covered by this
licence and is not redistributed in this repository.
