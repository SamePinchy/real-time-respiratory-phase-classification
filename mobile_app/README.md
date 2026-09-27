# Mobile Application — Setup

Flutter project targeting Android. Two files are intentionally **not** included
in this repository and have to be added before the first build.

---

## 1. Model file

Copy the exported model into the assets directory:

```bash
cp ../models/breathing_model.onnx assets/
```

The asset path is declared in `pubspec.yaml`. If your exported model has a
different file name, update the declaration and the path used when the ONNX
Runtime session is created.

---

## 2. Test-mode recording

The application can replay a recorded signal instead of connecting to the
measurement belt, which allows the whole processing pipeline and the user
interface to be exercised without the hardware. The recording is read from
`lib/testchart/`.

Any file in the training-pipeline format will work, for example:

```bash
cp ../data/labels/nagranie_kontrolne_manual.txt lib/testchart/
```

### Expected file format

One sample per line, three comma-separated columns:

```text
value,label,time
```

| Column | Meaning |
|---|---|
| `value` | signal amplitude normalised to the range −1 … 1 |
| `label` | phase indicator: `1` inhalation, `-1` exhalation, `2` post-inhalation retention, `0` post-exhalation retention |
| `time` | elapsed time in seconds from the beginning of the recording |

Example:

```text
-0.929935915662389090,-1.000000000000000000,5.105000000000000426
-0.944353798035914460,-1.000000000000000000,5.189000000000000057
-0.965140744953089103,-1.000000000000000000,5.298000000000000043
```

The label column is not used by the application — phases are produced by the
classifier — but it is part of the format and must be present.

Raw exports from the application (`data/recordings/`) use a different format
and have to be converted first:

```bash
python ../analysis/prepare/przygotuj_nagranie_uczace.py \
       ../data/recordings/pomiar2.txt lib/testchart/pomiar2_test.txt
```

If the file name differs from the default, update it in
`lib/services/mock_data_service.dart`.

---

## Build

```bash
flutter pub get
flutter run --release
```

Use the release configuration for any timing measurements. In debug builds the
additional Dart runtime checks make inference times considerably longer and the
results are not representative.

---

## Requirements

- Android 16 was used during development and testing.
- Bluetooth and location permissions are declared in the manifest and must be
  granted on first run for the belt connection to work.
- The measurement module has to be powered on and advertising before scanning.

Test mode requires neither permissions nor hardware.

