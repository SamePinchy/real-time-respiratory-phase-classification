# Real-Time Respiratory Phase Classification

Source code, measurement recordings, trained models, and supporting tools developed for the master's thesis:

**Modeling the Respiratory System with Artificial Neural Networks**

Author: **Jakub Kabat**  
Gdańsk University of Technology

## Overview

This project implements a system for real-time recognition of respiratory cycle phases from a strain-sensing belt signal.

The system distinguishes four respiratory phases:

- inhalation,
- exhalation,
- post-inhalation retention,
- post-exhalation retention.

A lightweight one-dimensional convolutional neural network processes consecutive signal windows. The network output is additionally processed using sequential constraints describing the allowable order of respiratory phases.

The model was trained in Python with PyTorch, exported to ONNX, and integrated with a Flutter mobile application using ONNX Runtime. All inference is performed locally on the mobile device.

The mechanical construction of the strain-sensing belt and the measurement electronics were developed as part of a parallel master's thesis. The present project focuses on the mobile application, signal processing, machine learning pipeline, sequential post-processing, and experimental evaluation.

---

## Repository Structure

```text
.
├── data/                   # Recordings collected by the author
├── mobile_app/             # Flutter mobile application
├── models/                 # Trained PyTorch and exported ONNX models
├── python/                 # Training, labeling, analysis and utility scripts
│   ├── analytics.py
│   ├── autolabel2.py
│   ├── chart_viewer.py
│   ├── metronom.py
│   ├── train_model.py
│   └── viterbi.py
└── README.md
```

The `data/` directory contains only recordings collected by the author for the purposes of the thesis. The external dataset used as the main source of training recordings is **not redistributed in this repository**.

---

## Respiratory Phase Classification

The classifier is a lightweight 1D convolutional neural network referred to in the project as `BreathingCNN`.

The default input consists of **30 consecutive samples**, corresponding to approximately **3 seconds** of respiratory signal.

The network contains **28,708 trainable parameters** and classifies each input window into one of four classes:

| Index | Phase |
|---:|---|
| 0 | Inhalation |
| 1 | Exhalation |
| 2 | Post-inhalation retention |
| 3 | Post-exhalation retention |

The trained network is stored in PyTorch format and is also exported to ONNX for use in the mobile application.

---

## Sequential Post-Processing

Each signal window is initially classified independently by the neural network.

The classifier output is then processed using a Viterbi-based decoder with a predefined transition matrix. The matrix describes which transitions between respiratory phases are allowed or forbidden. These transition constraints are defined manually and are not learned from the training dataset.

A minimum phase-duration filter is also used to suppress very short phase detections.

The implementation and its limitations are described in detail in the thesis. In particular, end-to-end testing showed that the current real-time processing scheme can still produce transitions that are inconsistent with the intended phase sequence.

---

## Mobile Application

The mobile application is implemented in **Flutter**.

Its main functions include:

- Bluetooth Low Energy communication with the measurement module,
- acquisition of respiratory signal samples,
- signal calibration and preprocessing,
- ONNX Runtime inference,
- sequential post-processing,
- visualization of the respiratory signal and detected phases,
- respiratory cycle and respiratory rate estimation,
- recording and export of measurement sessions,
- test mode based on previously recorded data.

The neural network runs directly on the mobile device and does not require cloud inference.

The complete Flutter project required to build the application is available in:

```text
mobile_app/
```

To run it:

```bash
cd mobile_app
flutter pub get
flutter run
```

To build a release APK:

```bash
flutter build apk --release
```

---

## Python Tools

The Python scripts used during development and evaluation are located in:

```text
python/
```

The main files are:

- `train_model.py` — training of the 1D CNN classifier,
- `autolabel2.py` — automatic phase labeling using the threshold-based rule,
- `viterbi.py` — sequential decoding and phase-transition constraints,
- `analytics.py` — analysis and evaluation of recorded data and model outputs,
- `chart_viewer.py` — visualization of respiratory recordings,
- `metronom.py` — utility used for metronome-guided respiratory recordings.

Some scripts were created specifically for the experiments described in the thesis and may require local file paths or small adjustments before being run in a different environment.

---

## Models

The `models/` directory contains:

- the trained PyTorch model (`.pt`),
- the exported ONNX model (`.onnx`).

The ONNX model is the version used by the Flutter application for mobile inference.

The final model contains **28,708 trainable parameters** and the exported ONNX file occupies approximately **116 kB**.

---

## Data

The `data/` directory contains measurement recordings collected by the author during the development and evaluation of the system.

These include recordings used for:

- computational performance measurements,
- end-to-end system validation,
- manual phase annotation,
- evaluation of respiratory rate estimation,
- experiments with additional manually labeled training material.

Only recordings collected by the author are included here.

### External training dataset

The original training material was based on the publicly available dataset:

> Szymański, J., Szefler, M., Karski, K., Krawczak, F., Jankowski, D.  
> *Parallel datasets for classification of respiratory rhythm phases.*  
> Scientific Data, 12, 346 (2025).  
> DOI: 10.1038/s41597-025-04625-5

Dataset repository:

https://doi.org/10.34808/ray2-4g53

The external dataset is not copied into this repository and remains subject to its original terms of use.

The recordings from that dataset were labeled again for this project using the threshold-based procedure implemented in `python/autolabel2.py`.

---

## Model Training

The training pipeline was implemented in Python using PyTorch.

The default configuration used in the thesis includes:

- input window: 30 samples,
- training stride: 3 samples,
- batch size: 256,
- epochs: 40,
- optimizer: Adam,
- initial learning rate: 0.001,
- weight decay: 0.0001,
- cross-entropy loss,
- cosine learning-rate schedule.

The training set is imbalanced, particularly for post-inhalation retention. Weighted sampling with replacement is therefore used to reduce the effect of class imbalance.

The model can be trained using:

```bash
cd python
python train_model.py
```

Depending on the local directory layout, dataset paths may need to be adjusted before training.

---

## Evaluation

The thesis evaluates the system at both model and complete-system level.

The experiments include:

- computational performance on a mobile device,
- influence of sequential post-processing,
- comparison with the threshold-based method,
- influence of input-window length,
- influence of manually annotated training data,
- respiratory rate estimation,
- end-to-end validation of the mobile processing pipeline.

Because the respiratory phase classes are imbalanced, **macro-F1** is used as the primary classification metric.

Manually annotated recordings were used as independent references for selected experiments.

---

## Selected Results

The final CNN contains **28,708 parameters**.

On the tested Samsung Galaxy S24 Ultra, median processing time for one incoming sample was approximately **0.7 ms**, compared with a sampling interval of approximately **100 ms**.

On a manually annotated reference segment, the neural-network-based method achieved:

- **macro-F1 = 0.818**
- threshold-based method: **macro-F1 = 0.755**

Adding 20 minutes of manually annotated difficult breathing patterns to the training material increased macro-F1 on a separate control recording from **0.828 to 0.876**.

For respiratory rate estimation, the cycle-detection criterion used in the system reduced the mean error from **1.907 breaths/min** to **0.395 breaths/min** compared with directly counting all transitions into inhalation.

---

## Known Limitations

This repository contains a research prototype developed for a master's thesis.

The main limitations identified during the evaluation include:

- limited amount of training and manually annotated data,
- limited number of users and measurement sessions,
- class imbalance, particularly for post-inhalation retention,
- differences between the original training recordings and later measurements,
- structural delay introduced by the temporal input window,
- additional delay introduced by phase-duration filtering,
- small procedural differences between the Python and mobile implementations,
- limitations of the current real-time sequential decoding procedure,
- gradual memory growth observed during longer mobile sessions.

The system is **not a medical device** and has not been validated for diagnostic use.

---

## Reproducibility Notes

The repository is intended to make the implementation and experimental material used in the thesis publicly available.

However, full reproduction of model training requires downloading the external training dataset separately from its original repository.

Some analysis scripts were developed specifically for individual experiments and may contain paths or parameters tied to the original project layout. These can be adjusted as needed.

---

## Master's Thesis

This repository accompanies the master's thesis:

**Modeling the Respiratory System with Artificial Neural Networks**

Polish title:

**Zastosowanie sztucznych sieci neuronowych w modelowaniu układu oddechowego**

Author: **Jakub Kabat**  
Gdańsk University of Technology

The repository contains the source code, models, and measurement recordings used during the development and evaluation of the system.

---

## Disclaimer

This project was developed for research and academic purposes.

It is **not a medical device**. Respiratory phase classifications and respiratory rate estimates produced by the system must not be interpreted as medical diagnoses.

---

## License

Add the selected software license here.

If the source code is released under the MIT License, include a `LICENSE` file in the repository. Measurement recordings can be distributed under a separate license if desired.
