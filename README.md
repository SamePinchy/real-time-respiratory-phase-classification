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

The signal level is intentionally preserved because it provides information required to distinguish post-inhalation and post-exhalation retention.

---

## Bluetooth Low Energy

The measurement module communicates with the mobile application using Bluetooth Low Energy.

The BLE service contains separate characteristics for:

- measurement data,
- control messages,
- calibration parameters.

Measurement packets contain:

- sequence number,
- raw sensor value,
- timestamp,
- integrity checksum.

Sequence numbering is used to detect missing packets, while an additional checksum is used to verify packet contents.

The application can also monitor connection quality and reconnect automatically after a connection loss.

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

A test data source is also available, allowing the processing pipeline and user interface to be tested without connecting the physical measurement belt.

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

The original training material consists of respiratory recordings containing several breathing patterns, including:

- normal breathing,
- shallow breathing,
- slow breathing,
- fast breathing,
- post-inhalation breath holds,
- post-exhalation breath holds,
- coughing.

The original training labels were generated automatically using a threshold-based method based on:

- the derivative of a smoothed respiratory signal,
- the absolute signal level.

Additional manually annotated recordings were used to investigate the influence of label quality and dataset diversity.

The repository contains the measurement data and scripts used to prepare the datasets used in the thesis experiments.

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

A manually annotated recording segment was used as a reference independent of both the neural network and the threshold-based labeling method.

---

## Selected Results

The implemented CNN contains **28,708 parameters**, and the exported ONNX model occupies approximately **116 kB**.

On the tested Android device, median processing time for one incoming sample was approximately **0.7 ms**, compared with an approximately **100 ms** sampling interval.

On the manually annotated reference segment, the neural-network-based approach achieved:

- **macro-F1: 0.818**
- threshold-based method: **0.755**

Additional experiments showed that extending the training dataset with manually annotated examples of difficult respiratory patterns increased macro-F1 on a separate control recording from **0.828 to 0.876**.

For respiratory rate estimation, the cycle detection criterion used in the system reduced the mean error to approximately **0.395 breaths/min** on the evaluated control recording.

These results should be interpreted together with the limitations described below.

---

## Known Limitations

This repository contains a research prototype rather than a production or medical system.

The main limitations identified during the thesis evaluation include:

- limited amount of training and manually annotated data,
- evaluation involving a limited number of measurement sessions and users,
- class imbalance, particularly for post-inhalation retention,
- differences between the signal characteristics of the original training recordings and later measurements,
- approximately 1.5 s structural delay caused by the context window, with additional delay introduced by phase-duration filtering,
- differences between the Python and mobile implementations of some processing steps,
- limitations of the current state handling in sequential decoding,
- gradual memory growth observed during longer mobile application sessions.

The system was not validated as a medical device.

Its outputs should not be interpreted as medical diagnoses.

---

## Repository Contents

The repository contains materials related to the implementation and experiments described in the thesis.

The exact directory names may change while the repository is being prepared for publication, but the project includes components corresponding to:

```text
.
├── mobile_app/          # Flutter mobile application
├── training/            # CNN training pipeline
├── preprocessing/       # Data preparation and labeling
├── evaluation/          # Evaluation and experiment scripts
├── data/                # Respiratory signal recordings and annotations
├── models/              # Trained / exported models
└── README.md
