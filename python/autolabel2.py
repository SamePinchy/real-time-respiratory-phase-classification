"""
Auto-labeler using the method from the reference scripts.

Core algorithm (from scripts/categorise_automatically.py):
  1. Apply moving-average smoothing (window 5, matching their tens-sensor setting)
  2. Compute derivative via np.gradient (central differences)
  3. Threshold per sample:
       |deriv| < 0.0079  ->  flat
       deriv  > 0        ->  increasing
       deriv  < 0        ->  decreasing
  4. Map flat + signal level to retention labels:
       flat and y > FLAT_THR  ->  2  (retention after inhale)
       flat and y <= FLAT_THR ->  0  (retention after exhale)
     (their pipeline assigned label 2 manually via GUI; this adds it automatically)

Label values written to column 2:
   1   inhale
  -1   exhale
   2   retention after inhale
   0   retention after exhale
"""

import os
import glob
import numpy as np

# ── Directories ──────────────────────────────────────────────────────────────
INPUT_DIR  = os.path.join(os.path.dirname(__file__), "labelled")
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "mylabels")

# ── Parameters (match reference scripts) ─────────────────────────────────────
SMOOTH_WINDOW = 5      # moving-average kernel size (their value for tens sensor)
DERIV_THR     = 0.0079 # |gradient| below this → flat  (from their monotonicity())
FLAT_THR      = 0.0    # y boundary: above → retention_inhale (2), below → retention_exhale (0)


def moving_average(arr, window):
    kernel = np.ones(window) / window
    return np.convolve(arr, kernel, mode="same")


def autolabel(y: np.ndarray) -> np.ndarray:
    smoothed = moving_average(y, SMOOTH_WINDOW)
    deriv    = np.gradient(smoothed)          # central differences, same as their code

    labels = np.where(
        np.abs(deriv) < DERIV_THR,
        np.where(smoothed > FLAT_THR, 2, 0),  # flat → retention_inhale or retention_exhale
        np.where(deriv > 0, 1, -1)             # moving → inhale or exhale
    )
    return labels.astype(int)


def process_file(src_path: str, dst_path: str):
    x_vals, y_vals = [], []
    raw_lines = []

    with open(src_path) as f:
        for line in f:
            raw_lines.append(line.rstrip())
            parts = line.strip().split(",")
            if len(parts) != 3:
                continue
            y_vals.append(float(parts[0]))
            x_vals.append(float(parts[2]))

    if not y_vals:
        print(f"  SKIP (no valid data): {os.path.basename(src_path)}")
        return

    labels = autolabel(np.array(y_vals))

    with open(dst_path, "w") as f:
        label_iter = iter(labels)
        for line in raw_lines:
            parts = line.split(",")
            if len(parts) != 3:
                f.write(line + "\n")
                continue
            lbl = next(label_iter)
            f.write(f"{parts[0]},{float(lbl):.18f},{parts[2]}\n")

    lbl_counts = {name: (labels == val).sum()
                  for name, val in [("inhale",1),("exhale",-1),("ret_in",2),("ret_ex",0)]}
    print(f"  {os.path.basename(src_path):35s}  "
          + "  ".join(f"{k}={v}" for k, v in lbl_counts.items()))


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    files = sorted(glob.glob(os.path.join(INPUT_DIR, "*.txt")))
    if not files:
        print(f"No .txt files found in {INPUT_DIR}")
        return

    print(f"Auto-labeling {len(files)} file(s)  [method: reference gradient, thr={DERIV_THR}]")
    print(f"  input  -> {INPUT_DIR}")
    print(f"  output -> {OUTPUT_DIR}\n")

    for src in files:
        dst = os.path.join(OUTPUT_DIR, os.path.basename(src))
        process_file(src, dst)

    print(f"\nDone. Files written to: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
