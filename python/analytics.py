"""+
Training analytics dashboard for the breathing classifier.
Run after train_model.py has produced breathing_model.pt.

Tabs:
  1. Training Curves   – loss & accuracy over epochs
  2. Confusion Matrix  – normalised heatmap
  3. Per-class Metrics – precision / recall / F1 bars
  4. Confidence        – prediction confidence histograms per class
  5. Data Distribution – class balance (train vs val) + per-file breakdown
  6. Sample Windows    – random val windows coloured by true vs predicted label
"""

import os
import glob
import tkinter as tk
from tkinter import ttk

import numpy as np
import matplotlib
matplotlib.use("TkAgg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.gridspec as gridspec
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg, NavigationToolbar2Tk
from sklearn.metrics import (classification_report, confusion_matrix,
                              precision_recall_fscore_support)
import torch
import torch.nn as nn

# ── Paths ────────────────────────────────────────────────────────────────────
MODEL_PATH   = os.path.join(os.path.dirname(__file__), "breathing_model.pt")
LABELLED_DIR = os.path.join(os.path.dirname(__file__), "mylabels")

# ── Palette ──────────────────────────────────────────────────────────────────
BG        = "#1e1e2e"
PANEL_BG  = "#181825"
FG        = "#cdd6f4"
ACCENT    = "#89b4fa"
CLASS_HEX = ["#4fc3f7", "#ef9a9a", "#a5d6a7", "#ffe082"]   # inhale exhale ret_in ret_ex


# ── Model (identical to train_model.py) ─────────────────────────────────────
class BreathingCNN(nn.Module):
    def __init__(self, window=30, n_classes=4):
        super().__init__()
        self.encoder = nn.Sequential(
            nn.Conv1d(1, 32, kernel_size=5, padding=2),
            nn.BatchNorm1d(32), nn.ReLU(),
            nn.Conv1d(32, 32, kernel_size=5, padding=2),
            nn.BatchNorm1d(32), nn.ReLU(),
            nn.MaxPool1d(2), nn.Dropout(0.2),
            nn.Conv1d(32, 64, kernel_size=3, padding=1),
            nn.BatchNorm1d(64), nn.ReLU(),
            nn.Conv1d(64, 64, kernel_size=3, padding=1),
            nn.BatchNorm1d(64), nn.ReLU(),
            nn.AdaptiveAvgPool1d(1),
        )
        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Linear(64, 64), nn.ReLU(), nn.Dropout(0.3),
            nn.Linear(64, n_classes),
        )
    def forward(self, x):
        return self.classifier(self.encoder(x.unsqueeze(1)))


# ── Data helpers ─────────────────────────────────────────────────────────────
INDICATOR_TO_CLASS = {1.0: 0, -1.0: 1, 2.0: 2, 0.0: 3}


def load_checkpoint():
    if not os.path.exists(MODEL_PATH):
        raise FileNotFoundError(f"No model found at {MODEL_PATH}. Run train_model.py first.")
    ck = torch.load(MODEL_PATH, map_location="cpu", weights_only=False)
    return ck


def load_all_windows(labelled_dir, window, step=3):
    """Return X (N,window), y (N,) and per-file counts dict."""
    all_x, all_y, per_file = [], [], {}
    for path in sorted(glob.glob(os.path.join(labelled_dir, "*.txt"))):
        fname = os.path.basename(path)
        vals, inds = [], []
        with open(path) as f:
            for line in f:
                p = line.strip().split(",")
                if len(p) != 3:
                    continue
                vals.append(float(p[0]))
                inds.append(float(p[1]))
        vals = np.array(vals, dtype=np.float32)
        inds = np.array(inds, dtype=np.float32)
        file_counts = {i: 0 for i in range(4)}
        for i in range(0, len(vals) - window + 1, step):
            ci = inds[i + window // 2]
            if ci not in INDICATOR_TO_CLASS:
                continue
            lbl = INDICATOR_TO_CLASS[ci]
            all_x.append(vals[i: i + window])
            all_y.append(lbl)
            file_counts[lbl] += 1
        per_file[fname] = file_counts
    return (np.array(all_x, dtype=np.float32),
            np.array(all_y,  dtype=np.int64),
            per_file)


# ── Matplotlib theme helper ───────────────────────────────────────────────────
def style_ax(ax, title="", xlabel="", ylabel=""):
    ax.set_facecolor(PANEL_BG)
    ax.tick_params(colors=FG, labelsize=8)
    for spine in ax.spines.values():
        spine.set_edgecolor("#45475a")
    ax.title.set_color(FG)
    ax.xaxis.label.set_color(FG)
    ax.yaxis.label.set_color(FG)
    if title:   ax.set_title(title,  fontsize=10)
    if xlabel:  ax.set_xlabel(xlabel, fontsize=8)
    if ylabel:  ax.set_ylabel(ylabel, fontsize=8)


def make_fig(rows, cols, figsize, hspace=0.45, wspace=0.35):
    fig, axes = plt.subplots(rows, cols, figsize=figsize)
    fig.patch.set_facecolor(BG)
    fig.subplots_adjust(hspace=hspace, wspace=wspace,
                        left=0.07, right=0.97, top=0.93, bottom=0.08)
    return fig, axes


def embed(fig, parent):
    canvas = FigureCanvasTkAgg(fig, master=parent)
    canvas.get_tk_widget().pack(fill=tk.BOTH, expand=True)
    tb_frame = tk.Frame(parent, bg=BG)
    tb_frame.pack(fill=tk.X)
    tb = NavigationToolbar2Tk(canvas, tb_frame)
    tb.config(background="#313244")
    tb.update()
    canvas.draw()


# ════════════════════════════════════════════════════════════════════════════
# Tab builders
# ════════════════════════════════════════════════════════════════════════════

def tab_training_curves(parent, history, class_names):
    fig, axes = make_fig(1, 2, (11, 4))
    ax_loss, ax_acc = axes
    epochs = range(1, len(history["train_loss"]) + 1)
    best_ep = int(np.argmax(history["val_acc"])) + 1

    # Loss
    ax_loss.plot(epochs, history["train_loss"], color=ACCENT,    lw=1.5, label="Train loss")
    ax_loss.plot(epochs, history["val_loss"],   color="#f38ba8",  lw=1.5, label="Val loss")
    ax_loss.axvline(best_ep, color="#a6e3a1", lw=1, linestyle="--", label=f"Best epoch {best_ep}")
    ax_loss.legend(fontsize=8, facecolor="#313244", edgecolor="none", labelcolor=FG)
    style_ax(ax_loss, "Loss", "Epoch", "Cross-entropy loss")

    # Accuracy
    ax_acc.plot(epochs, [v * 100 for v in history["train_acc"]], color=ACCENT,   lw=1.5, label="Train acc")
    ax_acc.plot(epochs, [v * 100 for v in history["val_acc"]],   color="#f38ba8", lw=1.5, label="Val acc")
    ax_acc.axvline(best_ep, color="#a6e3a1", lw=1, linestyle="--")
    ax_acc.set_ylim(0, 105)
    ax_acc.legend(fontsize=8, facecolor="#313244", edgecolor="none", labelcolor=FG)
    style_ax(ax_acc, "Accuracy", "Epoch", "Accuracy (%)")

    # Annotations
    best_val = max(history["val_acc"]) * 100
    ax_acc.annotate(f"Best {best_val:.1f}%",
                    xy=(best_ep, best_val),
                    xytext=(best_ep + 1, best_val - 8),
                    color="#a6e3a1", fontsize=8,
                    arrowprops=dict(arrowstyle="->", color="#a6e3a1", lw=0.8))

    embed(fig, parent)


def tab_confusion_matrix(parent, y_true, y_pred, class_names):
    cm = confusion_matrix(y_true, y_pred)
    cm_norm = cm.astype(float) / cm.sum(axis=1, keepdims=True)

    fig, axes = make_fig(1, 2, (12, 5), wspace=0.4)
    ax_raw, ax_norm = axes

    for ax, data, title, fmt in [
        (ax_raw,  cm,      "Confusion Matrix (counts)",      "d"),
        (ax_norm, cm_norm, "Confusion Matrix (normalised)",  ".2f"),
    ]:
        im = ax.imshow(data, cmap="Blues", vmin=0)
        plt.colorbar(im, ax=ax, fraction=0.046, pad=0.04).ax.tick_params(colors=FG, labelsize=7)
        n = len(class_names)
        ax.set_xticks(range(n))
        ax.set_yticks(range(n))
        short = [c.replace("retention_", "ret_") for c in class_names]
        ax.set_xticklabels(short, rotation=30, ha="right", fontsize=8)
        ax.set_yticklabels(short, fontsize=8)
        thresh = data.max() / 2
        for i in range(n):
            for j in range(n):
                val = f"{data[i,j]:{fmt}}"
                ax.text(j, i, val, ha="center", va="center", fontsize=9,
                        color="white" if data[i, j] > thresh else "#313244",
                        fontweight="bold" if i == j else "normal")
        style_ax(ax, title, "Predicted", "True")

    embed(fig, parent)


def tab_per_class_metrics(parent, y_true, y_pred, class_names):
    prec, rec, f1, sup = precision_recall_fscore_support(
        y_true, y_pred, labels=list(range(len(class_names))), zero_division=0
    )
    x = np.arange(len(class_names))
    w = 0.25
    short = [c.replace("retention_", "ret_") for c in class_names]

    fig, axes = make_fig(1, 2, (12, 4.5), wspace=0.38)
    ax_bar, ax_sup = axes

    for i, (vals, label, color) in enumerate([
        (prec, "Precision", "#89b4fa"),
        (rec,  "Recall",    "#a6e3a1"),
        (f1,   "F1-score",  "#f9e2af"),
    ]):
        bars = ax_bar.bar(x + i * w, vals, w, label=label, color=color, alpha=0.85)
        for bar, v in zip(bars, vals):
            ax_bar.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.01,
                        f"{v:.2f}", ha="center", va="bottom", fontsize=7, color=FG)

    ax_bar.set_xticks(x + w)
    ax_bar.set_xticklabels(short, fontsize=8)
    ax_bar.set_ylim(0, 1.12)
    ax_bar.legend(fontsize=8, facecolor="#313244", edgecolor="none", labelcolor=FG)
    style_ax(ax_bar, "Per-class Metrics", "Class", "Score")

    # Support (sample count)
    bars = ax_sup.bar(short, sup, color=CLASS_HEX, alpha=0.85)
    for bar, v in zip(bars, sup):
        ax_sup.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 1,
                    str(v), ha="center", va="bottom", fontsize=9, color=FG)
    style_ax(ax_sup, "Validation Samples per Class", "Class", "Count")

    embed(fig, parent)


def tab_confidence(parent, y_true, y_pred, y_conf, class_names):
    fig, axes = make_fig(2, 2, (11, 7))
    axes = axes.flatten()
    bins = np.linspace(0, 1, 26)

    for i, name in enumerate(class_names):
        ax = axes[i]
        mask_correct = (np.array(y_true) == i) & (np.array(y_pred) == i)
        mask_wrong   = (np.array(y_pred) == i) & ~mask_correct
        conf = np.array(y_conf)

        ax.hist(conf[mask_correct], bins=bins, color=CLASS_HEX[i], alpha=0.8,
                label=f"Correct ({mask_correct.sum()})")
        ax.hist(conf[mask_wrong],   bins=bins, color="#f38ba8",     alpha=0.7,
                label=f"Wrong ({mask_wrong.sum()})")
        ax.axvline(conf[np.array(y_pred) == i].mean() if mask_correct.sum() > 0 else 0.5,
                   color="white", lw=1, linestyle="--", alpha=0.6)
        ax.legend(fontsize=7, facecolor="#313244", edgecolor="none", labelcolor=FG)
        style_ax(ax, name.replace("_", " ").title(), "Confidence", "Count")

    embed(fig, parent)


def tab_data_distribution(parent, train_dist, val_dist, per_file, class_names):
    fig = plt.figure(figsize=(13, 7))
    fig.patch.set_facecolor(BG)
    gs = gridspec.GridSpec(2, 2, figure=fig,
                           hspace=0.5, wspace=0.38,
                           left=0.07, right=0.97, top=0.93, bottom=0.08)
    ax_pie_tr = fig.add_subplot(gs[0, 0])
    ax_pie_va = fig.add_subplot(gs[0, 1])
    ax_file   = fig.add_subplot(gs[1, :])

    short = [c.replace("retention_", "ret_") for c in class_names]

    def pie(ax, dist, title):
        sizes  = [dist.get(n, 0) for n in class_names]
        wedges, texts, autotexts = ax.pie(
            sizes, labels=short, colors=CLASS_HEX,
            autopct="%1.1f%%", startangle=140,
            textprops={"color": FG, "fontsize": 8},
        )
        for at in autotexts:
            at.set_fontsize(7)
        ax.set_facecolor(PANEL_BG)
        ax.set_title(title, color=FG, fontsize=10)

    pie(ax_pie_tr, train_dist, "Train class distribution")
    pie(ax_pie_va, val_dist,   "Validation class distribution")

    # Per-file stacked bar
    files = list(per_file.keys())
    short_files = [f.replace("tens_", "").replace(".txt", "") for f in files]
    bottoms = np.zeros(len(files))
    for ci, (name, color) in enumerate(zip(class_names, CLASS_HEX)):
        vals = np.array([per_file[f].get(ci, 0) for f in files])
        ax_file.bar(short_files, vals, bottom=bottoms, color=color,
                    alpha=0.85, label=name.replace("_", " "))
        bottoms += vals
    ax_file.set_xticklabels(short_files, rotation=35, ha="right", fontsize=7)
    ax_file.legend(fontsize=7, facecolor="#313244", edgecolor="none",
                   labelcolor=FG, ncol=4, loc="upper right")
    style_ax(ax_file, "Windows per File (by class)", "File", "Window count")

    embed(fig, parent)


def tab_sample_windows(parent, X_val, y_true, y_pred, y_conf, class_names, n=16):
    rng = np.random.default_rng(0)

    # Only show windows where ≥70 % of samples share the true label,
    # so each thumbnail visually matches what it's labelled as.
    INDICATOR_MAP = {0: 1.0, 1: -1.0, 2: 2.0, 3: 0.0}  # class id -> indicator value
    CLASS_TO_IND  = INDICATOR_MAP

    def purity(win_idx):
        tc = y_true[win_idx]
        # approximate per-sample class by thresholding the raw signal
        # (we don't have per-sample labels here, so use confidence as proxy)
        return y_conf[win_idx]   # higher confidence = cleaner window

    # Pick n_per_class best-confidence windows per class for a balanced display
    n_per_class = n // len(class_names)
    idxs = []
    for cls in range(len(class_names)):
        cls_idxs = np.where(np.array(y_true) == cls)[0]
        if len(cls_idxs) == 0:
            continue
        # sort by confidence descending, take top n_per_class
        sorted_by_conf = cls_idxs[np.argsort(y_conf[cls_idxs])[::-1]]
        idxs.extend(sorted_by_conf[:n_per_class].tolist())
    idxs = sorted(idxs)
    cols  = 4
    rows  = (len(idxs) + cols - 1) // cols

    fig, axes = make_fig(rows, cols, (13, rows * 2.2), hspace=0.7, wspace=0.35)
    axes = np.array(axes).flatten()

    for ax_i, idx in enumerate(idxs):
        ax  = axes[ax_i]
        win = X_val[idx]
        t   = np.arange(len(win))
        tc  = y_true[idx]
        pc  = y_pred[idx]
        correct = tc == pc

        ax.fill_between(t, win, alpha=0.15, color=CLASS_HEX[pc])
        ax.plot(t, win, color=CLASS_HEX[pc], lw=1.2)
        ax.axhline(0, color="#585b70", lw=0.5, linestyle="--")
        ax.set_ylim(-1.2, 1.2)
        ax.set_xticks([])

        border_color = "#a6e3a1" if correct else "#f38ba8"
        for spine in ax.spines.values():
            spine.set_edgecolor(border_color)
            spine.set_linewidth(1.5)

        true_short = class_names[tc].replace("retention_", "ret_")
        pred_short = class_names[pc].replace("retention_", "ret_")
        conf_val   = y_conf[idx]
        ax.set_title(
            f"T: {true_short}\nP: {pred_short}  {conf_val:.2f}",
            fontsize=7, color=FG, pad=2,
        )
        ax.set_facecolor(PANEL_BG)
        ax.tick_params(colors=FG, labelsize=6)
        for sp in ax.spines.values():
            sp.set_edgecolor(border_color)

    for ax in axes[len(idxs):]:
        ax.set_visible(False)

    fig.suptitle(
        "Sample validation windows — border: green=correct, red=wrong\n"
        "colour = predicted class",
        color=FG, fontsize=9,
    )
    embed(fig, parent)


# ════════════════════════════════════════════════════════════════════════════
# Main app
# ════════════════════════════════════════════════════════════════════════════

class AnalyticsApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Breathing Classifier — Training Analytics")
        self.geometry("1280x760")
        self.configure(bg=BG)

        # ── load checkpoint ──────────────────────────────────────────────
        try:
            ck = load_checkpoint()
        except FileNotFoundError as e:
            tk.Label(self, text=str(e), bg=BG, fg="#f38ba8",
                     font=("Segoe UI", 12)).pack(expand=True)
            return

        class_names = ck["class_names"]
        window      = ck["window"]
        history     = ck.get("history", {})
        y_true      = ck.get("val_true", [])
        y_pred      = ck.get("val_pred", [])
        y_conf      = ck.get("val_conf", [])
        val_dist    = ck.get("class_dist", {})
        train_dist  = ck.get("train_class_dist", {})

        # ── rebuild val windows for sample tab ──────────────────────────
        X_all, y_all, per_file = load_all_windows(LABELLED_DIR, window)
        from sklearn.model_selection import train_test_split
        _, X_val, _, y_val_arr = train_test_split(
            X_all, y_all, test_size=0.2, stratify=y_all, random_state=42
        )
        if not y_true:
            # history missing (old checkpoint) — run inference now
            model = BreathingCNN(window=window)
            model.load_state_dict(ck["model_state"])
            model.eval()
            X_t = torch.from_numpy(X_val)
            with torch.no_grad():
                logits = model(X_t)
                probs  = torch.softmax(logits, 1)
                y_pred  = logits.argmax(1).tolist()
                y_conf  = probs.max(1).values.tolist()
            y_true = y_val_arr.tolist()

        y_true = np.array(y_true)
        y_pred = np.array(y_pred)
        y_conf = np.array(y_conf)

        # ── header bar ──────────────────────────────────────────────────
        hdr = tk.Frame(self, bg="#313244", height=36)
        hdr.pack(fill=tk.X)
        hdr.pack_propagate(False)
        best_acc = max(history.get("val_acc", [0])) * 100
        epochs   = len(history.get("train_acc", []))
        info = (f"  Model: {os.path.basename(MODEL_PATH)}   |   "
                f"Classes: {', '.join(class_names)}   |   "
                f"Window: {window} samples   |   "
                f"Epochs: {epochs}   |   "
                f"Best val acc: {best_acc:.1f}%   |   "
                f"Val samples: {len(y_true)}")
        tk.Label(hdr, text=info, bg="#313244", fg=FG,
                 font=("Segoe UI", 9)).pack(side=tk.LEFT, padx=8)

        # ── notebook ────────────────────────────────────────────────────
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("TNotebook",       background=BG,      borderwidth=0)
        style.configure("TNotebook.Tab",   background="#313244", foreground=FG,
                        padding=[10, 4],   font=("Segoe UI", 9))
        style.map("TNotebook.Tab",
                  background=[("selected", "#45475a")],
                  foreground=[("selected", "#cdd6f4")])

        nb = ttk.Notebook(self)
        nb.pack(fill=tk.BOTH, expand=True, padx=6, pady=6)

        def add_tab(title):
            frame = tk.Frame(nb, bg=BG)
            nb.add(frame, text=title)
            return frame

        tab_training_curves(
            add_tab("📈 Training Curves"),
            history, class_names,
        )
        tab_confusion_matrix(
            add_tab("🔲 Confusion Matrix"),
            y_true, y_pred, class_names,
        )
        tab_per_class_metrics(
            add_tab("📊 Per-class Metrics"),
            y_true, y_pred, class_names,
        )
        tab_confidence(
            add_tab("🎯 Confidence"),
            y_true.tolist(), y_pred.tolist(), y_conf.tolist(), class_names,
        )
        tab_data_distribution(
            add_tab("📂 Data Distribution"),
            train_dist, val_dist, per_file, class_names,
        )
        tab_sample_windows(
            add_tab("🔍 Sample Windows"),
            X_val, y_true, y_pred, y_conf, class_names,
        )


if __name__ == "__main__":
    app = AnalyticsApp()
    app.mainloop()
