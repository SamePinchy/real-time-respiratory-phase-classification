# Real-Time Respiratory Phase Classification

This repository contains the source code, training pipeline, evaluation scripts, and measurement data developed for the master's thesis:

**"Modeling the Respiratory System with Artificial Neural Networks"**

The project focuses on real-time recognition of respiratory cycle phases using a strain-sensor belt and a mobile device.

The system distinguishes four respiratory phases:

- inhalation,
- exhalation,
- post-inhalation retention,
- post-exhalation retention.

A lightweight one-dimensional convolutional neural network is used to classify consecutive signal windows. The network output is additionally processed using sequential constraints based on the allowable order of respiratory phases.

The trained model is exported to the ONNX format and executed directly on an Android mobile device using ONNX Runtime. The mobile application was developed in Flutter.

---

## Project Overview

The complete processing pipeline consists of:

1. acquisition of the respiratory signal from a strain-sensor belt,
2. transmission of measurement data using Bluetooth Low Energy,
3. conversion and preprocessing of the recorded signal,
4. respiratory phase classification using a 1D convolutional neural network,
5. sequential post-processing of classifier outputs,
6. respiratory cycle and respiratory rate estimation,
7. visualization and storage of measurement results in the mobile application.

The project was designed for real-time operation directly on a mobile device without requiring remote inference or cloud processing.

---

## Respiratory Phases

The model classifies each analyzed signal window into one of four classes:

| Class | Description |
|---|---|
| Inhalation | Increasing chest circumference during inspiration |
| Exhalation | Decreasing chest circumference during expiration |
| Post-inhalation retention | Breath-hold or pause occurring after inhalation |
| Post-exhalation retention | Breath-hold or pause occurring after exhalation |

The distinction between the two retention phases is based not only on the local signal dynamics but also on the signal level and the temporal context.

---

## Model

The respiratory phase classifier is a lightweight 1D convolutional neural network implemented in Python.

The model contains approximately **28.7k trainable parameters** and was designed with mobile inference in mind.

The default input consists of a window of **30 consecutive samples**, corresponding to approximately **3 seconds** of signal at the sampling frequency used in the system.

The model is trained using PyTorch and exported to the ONNX format for use in the mobile application.

Main components of the network include:

- one-dimensional convolutional layers,
- batch normalization,
- ReLU activation,
- pooling,
- dropout,
- global average pooling,
- fully connected classification layers.

---

## Sequential Post-Processing

Raw neural network predictions are additionally processed using sequential constraints.

The respiratory cycle follows a limited set of valid transitions between phases. These constraints are applied using a Viterbi-based decoding procedure.

The post-processing stage is intended to reduce unrealistic phase sequences and improve temporal consistency of the output.

A minimum phase duration filter is also applied to suppress very short phase detections.

---

## Signal Preprocessing

The raw measurement signal is converted to a normalized representation before being passed to the classifier.

The preprocessing pipeline includes:

- conversion of raw sensor values,
- estimation of the operating range,
- calibration of the resting signal level,
- handling of long-term signal drift,
- preparation of fixed-length input windows.

The project includes both an algorithm based on local minimum detection and a rolling calibration method used during real-time operation.

---

## Mobile Application

The mobile application was developed using **Flutter**.

It is responsible for:

- Bluetooth Low Energy communication,
- receiving measurement packets,
- packet integrity verification,
- signal preprocessing,
- ONNX Runtime inference,
- sequential post-processing,
- respiratory phase visualization,
- respiratory rate estimation,
- recording measurement sessions,
- exporting stored results.

Inference is performed directly on the mobile device.

---

## Training Pipeline

The training and evaluation pipeline was implemented in Python.

It includes tools for:

- loading recorded respiratory signals,
- automatic phase labeling,
- manual-label processing,
- signal normalization,
- generation of overlapping training windows,
- class balancing,
- CNN training,
- ONNX export,
- model evaluation,
- confusion matrix generation,
- comparison of different preprocessing and post-processing variants.

The training procedure uses weighted sampling to reduce the influence of class imbalance.

---

## Dataset

The repository contains measurement data used during model development and evaluation.

The original training dataset was labeled using a threshold-based rule derived from the signal derivative and signal level.

Additional manually labeled recordings were later used to evaluate the influence of label quality and dataset diversity on classification performance.

The dataset contains signals representing:

- normal spontaneous breathing,
- shallow breathing,
- slow breathing,
- breath holds,
- variable respiratory patterns.

Some recordings were manually annotated to provide an independent reference for evaluating phase boundaries.

More detailed information about individual recordings and file formats can be found in the `data/` directory.

---

## Evaluation

The system was evaluated at both model and complete-system level.

The experiments include:

- classification quality evaluation,
- comparison with a threshold-based algorithm,
- analysis of class imbalance,
- influence of input window length,
- influence of sequential post-processing,
- influence of manually labeled training data,
- respiratory rate estimation,
- execution time measurements on a mobile device,
- memory usage analysis,
- end-to-end validation of the mobile processing pipeline.

The primary classification metric used in the experiments is **macro-F1**, as the respiratory phase classes are not equally represented.

---

## Example Results

The experiments showed that the neural network provides better respiratory phase recognition than the earlier threshold-based approach, particularly for breath-hold phases.

On manually annotated evaluation data, the complete system achieved macro-F1 values above 0.8, depending on the recording and processing configuration.

Adding manually annotated difficult examples to the training set further improved classification performance and reduced variability between independent training runs.

The mobile implementation also provides a large computational margin relative to the approximately 100 ms interval between incoming samples.

---

## Repository Structure

An example repository structure is shown below:

```text
real-time-respiratory-phase-classification/
│
├── mobile_app/
│   └── Flutter mobile application
│
├── training/
│   └── Neural network training scripts
│
├── preprocessing/
│   └── Signal preprocessing and labeling tools
│
├── evaluation/
│   └── Evaluation and analysis scripts
│
├── models/
│   └── Trained and exported models
│
├── data/
│   └── Measurement recordings and annotations
│
├── results/
│   └── Generated experiment results
│
├── requirements.txt
├── README.md
└── LICENSE
