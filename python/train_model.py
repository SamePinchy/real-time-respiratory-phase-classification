"""
Breathing phase classifier — 1D CNN
Classes: inhale | exhale | retention_inhale | retention_exhale
Labels in data files:
   indicator  1  -> inhale
   indicator -1  -> exhale
   indicator  2  -> retention_inhale
   indicator  0  -> retention_exhale
   indicator 999 -> skip (corrupt)
"""

import os
import glob
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset, WeightedRandomSampler
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report, confusion_matrix
from viterbi import viterbi

# ── Config ─────────────────────────────────────────────────────────────────
LABELLED_DIR = os.path.join(os.path.dirname(__file__), "mylabels")
MODEL_PATH   = os.path.join(os.path.dirname(__file__), "breathing_model.pt")
WINDOW       = 30       # samples (~3 s at ~9.8 Hz)
STEP         = 3        # stride between windows
BATCH        = 256
EPOCHS       = 40
LR           = 1e-3
SEED         = 42

INDICATOR_TO_CLASS = {1.0: 0, -1.0: 1, 2.0: 2, 0.0: 3}
CLASS_NAMES = ["inhale", "exhale", "retention_inhale", "retention_exhale"]
MAJORITY_THR = 0.80   # fraction of window samples that must share one class

torch.manual_seed(SEED)
np.random.seed(SEED)


# ── Data loading ────────────────────────────────────────────────────────────
def load_file(path):
    rows = []
    with open(path) as f:
        for line in f:
            parts = line.strip().split(",")
            if len(parts) != 3:
                continue
            y, ind, x = float(parts[0]), float(parts[1]), float(parts[2])
            rows.append((y, ind))
    return rows


def build_dataset():
    all_x, all_y = [], []
    files = glob.glob(os.path.join(LABELLED_DIR, "*.txt"))
    for path in files:
        rows = load_file(path)
        values   = np.array([r[0] for r in rows], dtype=np.float32)
        indicators = np.array([r[1] for r in rows], dtype=np.float32)

        for i in range(0, len(values) - WINDOW + 1, STEP):
            # label = class of the centre sample in the window
            centre_ind = indicators[i + WINDOW // 2]
            if centre_ind not in INDICATOR_TO_CLASS:
                continue
            label = INDICATOR_TO_CLASS[centre_ind]

            window = values[i : i + WINDOW]
            all_x.append(window)
            all_y.append(label)

    X = np.array(all_x, dtype=np.float32)   # (N, WINDOW)
    y = np.array(all_y, dtype=np.int64)
    return X, y


# ── Model ───────────────────────────────────────────────────────────────────
class BreathingCNN(nn.Module):
    def __init__(self, window=WINDOW, n_classes=4):
        super().__init__()
        self.encoder = nn.Sequential(
            # block 1
            nn.Conv1d(1, 32, kernel_size=5, padding=2),
            nn.BatchNorm1d(32),
            nn.ReLU(),
            nn.Conv1d(32, 32, kernel_size=5, padding=2),
            nn.BatchNorm1d(32),
            nn.ReLU(),
            nn.MaxPool1d(2),          # -> window/2
            nn.Dropout(0.2),
            # block 2
            nn.Conv1d(32, 64, kernel_size=3, padding=1),
            nn.BatchNorm1d(64),
            nn.ReLU(),
            nn.Conv1d(64, 64, kernel_size=3, padding=1),
            nn.BatchNorm1d(64),
            nn.ReLU(),
            nn.AdaptiveAvgPool1d(1),  # global avg pool -> (B, 64, 1)
        )
        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Linear(64, 64),
            nn.ReLU(),
            nn.Dropout(0.3),
            nn.Linear(64, n_classes),
        )

    def forward(self, x):                  # x: (B, window)
        x = x.unsqueeze(1)                 # -> (B, 1, window)
        x = self.encoder(x)
        return self.classifier(x)


# ── Training ─────────────────────────────────────────────────────────────────
def make_weighted_sampler(y_train):
    counts = np.bincount(y_train, minlength=4)
    weights_per_class = 1.0 / (counts + 1e-6)
    sample_weights = torch.tensor([weights_per_class[c] for c in y_train],
                                  dtype=torch.float32)
    return WeightedRandomSampler(sample_weights, len(sample_weights))


def train():
    print("Loading data …")
    X, y = build_dataset()
    print(f"  Total windows: {len(X)}")
    for i, name in enumerate(CLASS_NAMES):
        print(f"    {name}: {(y == i).sum()}")

    X_tr, X_val, y_tr, y_val = train_test_split(
        X, y, test_size=0.2, stratify=y, random_state=SEED
    )

    ds_tr  = TensorDataset(torch.from_numpy(X_tr), torch.from_numpy(y_tr))
    ds_val = TensorDataset(torch.from_numpy(X_val), torch.from_numpy(y_val))

    sampler = make_weighted_sampler(y_tr)
    dl_tr  = DataLoader(ds_tr, batch_size=BATCH, sampler=sampler)
    dl_val = DataLoader(ds_val, batch_size=BATCH, shuffle=False)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"\nTraining on {device}")

    model = BreathingCNN().to(device)
    optim = torch.optim.Adam(model.parameters(), lr=LR, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optim, T_max=EPOCHS)
    criterion = nn.CrossEntropyLoss()

    history = {"train_loss": [], "train_acc": [], "val_acc": [], "val_loss": []}
    best_val_acc = 0.0
    for epoch in range(1, EPOCHS + 1):
        # — train —
        model.train()
        tr_loss = tr_correct = tr_total = 0
        for xb, yb in dl_tr:
            xb, yb = xb.to(device), yb.to(device)
            optim.zero_grad()
            logits = model(xb)
            loss = criterion(logits, yb)
            loss.backward()
            optim.step()
            tr_loss    += loss.item() * len(yb)
            tr_correct += (logits.argmax(1) == yb).sum().item()
            tr_total   += len(yb)
        scheduler.step()

        # — validate —
        model.eval()
        val_loss = val_correct = val_total = 0
        with torch.no_grad():
            for xb, yb in dl_val:
                xb, yb = xb.to(device), yb.to(device)
                logits = model(xb)
                val_loss    += criterion(logits, yb).item() * len(yb)
                val_correct += (logits.argmax(1) == yb).sum().item()
                val_total   += len(yb)

        tr_acc  = tr_correct  / tr_total
        val_acc = val_correct / val_total
        history["train_loss"].append(tr_loss  / tr_total)
        history["val_loss"].append(  val_loss / val_total)
        history["train_acc"].append(tr_acc)
        history["val_acc"].append(  val_acc)
        print(f"Epoch {epoch:3d}/{EPOCHS}  "
              f"loss {tr_loss/tr_total:.4f}  "
              f"train {tr_acc:.3f}  val {val_acc:.3f}")

        if val_acc > best_val_acc:
            best_val_acc = val_acc
            torch.save({"model_state": model.state_dict(),
                        "window": WINDOW,
                        "class_names": CLASS_NAMES,
                        "history": history},
                       MODEL_PATH)

    # — final report —
    print(f"\nBest val accuracy: {best_val_acc:.3f}")
    checkpoint = torch.load(MODEL_PATH, weights_only=False)
    model.load_state_dict(checkpoint["model_state"])
    model.eval()

    all_log_probs, all_true, all_conf = [], [], []
    with torch.no_grad():
        for xb, yb in dl_val:
            xb = xb.to(device)
            logits = model(xb)
            log_probs = torch.log_softmax(logits, dim=1)
            probs     = torch.softmax(logits, dim=1)
            all_log_probs.extend(log_probs.cpu().tolist())
            all_true.extend(yb.tolist())
            all_conf.extend(probs.max(1).values.cpu().tolist())

    # apply Viterbi over the full validation sequence
    log_probs_arr = np.array(all_log_probs, dtype=np.float32)
    all_pred = viterbi(log_probs_arr).tolist()

    print("\nClassification report WITHOUT Viterbi (raw CNN):")
    raw_pred = log_probs_arr.argmax(axis=1).tolist()
    print(classification_report(all_true, raw_pred, target_names=CLASS_NAMES))
    print("\nClassification report WITH Viterbi (sequence constraints):")
    print(classification_report(all_true, all_pred, target_names=CLASS_NAMES))

    # save val results into checkpoint so analytics.py can load them
    checkpoint = torch.load(MODEL_PATH, weights_only=False)
    checkpoint["val_true"]  = all_true
    checkpoint["val_pred"]  = all_pred
    checkpoint["val_conf"]  = all_conf
    checkpoint["class_dist"] = {name: int((np.array(all_true) == i).sum())
                                 for i, name in enumerate(CLASS_NAMES)}
    checkpoint["train_class_dist"] = {name: int((y_tr == i).sum())
                                       for i, name in enumerate(CLASS_NAMES)}
    torch.save(checkpoint, MODEL_PATH)

    print("\nClassification report (validation set):")
    print(classification_report(all_true, all_pred, target_names=CLASS_NAMES))
    print("Confusion matrix (rows=true, cols=pred):")
    print(confusion_matrix(all_true, all_pred))
    print(f"\nModel saved to {MODEL_PATH}")


if __name__ == "__main__":
    train()
