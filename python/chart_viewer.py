import os
import tkinter as tk
from tkinter import ttk
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg, NavigationToolbar2Tk
import numpy as np
from viterbi import viterbi

# ── optional model inference ─────────────────────────────────────────────────
try:
    import torch
    import torch.nn as nn

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

    MODEL_PATH = os.path.join(os.path.dirname(__file__), "breathing_model.pt")
    _checkpoint = torch.load(MODEL_PATH, map_location="cpu", weights_only=False)
    _model = BreathingCNN(window=_checkpoint["window"])
    _model.load_state_dict(_checkpoint["model_state"])
    _model.eval()
    _CLASS_NAMES = _checkpoint["class_names"]
    _WINDOW = _checkpoint["window"]
    MODEL_AVAILABLE = True
except Exception:
    MODEL_AVAILABLE = False

# ── constants ────────────────────────────────────────────────────────────────
LABELLED_DIR = os.path.join(os.path.dirname(__file__), "mylabels")
WINDOW_SEC   = 20.0

INDICATOR_TO_LABEL = {1.0: "inhale", -1.0: "exhale", 2.0: "retention_inhale", 0.0: "retention_exhale"}
CLASS_COLORS = {
    "inhale":            "#4fc3f7",
    "exhale":            "#ef9a9a",
    "retention_inhale":  "#a5d6a7",
    "retention_exhale":  "#ffe082",
}


def load_file(path):
    x, y, valid, true_labels = [], [], [], []
    with open(path) as f:
        for line in f:
            parts = line.strip().split(",")
            if len(parts) != 3:
                continue
            y_val, ind, x_val = float(parts[0]), float(parts[1]), float(parts[2])
            x.append(x_val)
            y.append(y_val)
            valid.append(ind != 999)
            true_labels.append(INDICATOR_TO_LABEL.get(ind, None))
    return (np.array(x), np.array(y), np.array(valid),
            np.array(true_labels, dtype=object))


def run_inference(values, use_viterbi=True):
    """Return per-sample predicted class name array (same length as values)."""
    if not MODEL_AVAILABLE:
        return None
    half   = _WINDOW // 2
    padded = np.pad(values, (half, half), mode="edge")
    idxs   = np.arange(0, len(values))
    batch  = np.stack([padded[i: i + _WINDOW] for i in idxs], axis=0).astype(np.float32)
    with torch.no_grad():
        logits    = _model(torch.from_numpy(batch))
        log_probs = torch.log_softmax(logits, dim=1).numpy()  # (T, C)

    if use_viterbi:
        cls_ids = viterbi(log_probs)
    else:
        cls_ids = log_probs.argmax(axis=1)

    return np.array([_CLASS_NAMES[c] for c in cls_ids], dtype=object)


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Breathing Classifier Viewer")
        self.geometry("1200x700")
        self.configure(bg="#1e1e2e")

        self._x = self._y = self._valid = self._true_labels = self._pred_labels = None
        self._x_min = self._x_max = 0.0
        # "ground_truth" | "predictions" | "both"
        self._color_source  = tk.StringVar(value="ground_truth")
        self._use_viterbi   = tk.BooleanVar(value=True)

        self._build_ui()
        self._populate_list()

    # ── UI layout ─────────────────────────────────────────────────────────────
    def _build_ui(self):
        left = tk.Frame(self, bg="#1e1e2e", width=200)
        left.pack(side=tk.LEFT, fill=tk.Y, padx=(10, 0), pady=10)
        left.pack_propagate(False)

        tk.Label(left, text="Files", bg="#1e1e2e", fg="#cdd6f4",
                 font=("Segoe UI", 11, "bold")).pack(anchor="w", pady=(0, 6))

        sb = ttk.Scrollbar(left, orient=tk.VERTICAL)
        self.listbox = tk.Listbox(
            left, yscrollcommand=sb.set,
            bg="#313244", fg="#cdd6f4", selectbackground="#89b4fa",
            selectforeground="#1e1e2e", font=("Segoe UI", 10),
            activestyle="none", relief=tk.FLAT, borderwidth=0,
        )
        sb.config(command=self.listbox.yview)
        sb.pack(side=tk.RIGHT, fill=tk.Y)
        self.listbox.pack(fill=tk.BOTH, expand=True)
        self.listbox.bind("<<ListboxSelect>>", self._on_select)

        # colour source selector
        opt_frame = tk.Frame(left, bg="#1e1e2e")
        opt_frame.pack(fill=tk.X, pady=(10, 0))
        tk.Label(opt_frame, text="Colour source", bg="#1e1e2e", fg="#a6adc8",
                 font=("Segoe UI", 9, "bold")).pack(anchor="w")
        for text, value in [("Ground truth labels", "ground_truth"),
                             ("Model predictions",   "predictions"),
                             ("Both",                "both")]:
            state = tk.NORMAL if (value == "ground_truth" or MODEL_AVAILABLE) else tk.DISABLED
            tk.Radiobutton(opt_frame, text=text, variable=self._color_source,
                           value=value, state=state,
                           bg="#1e1e2e", fg="#cdd6f4", selectcolor="#313244",
                           activebackground="#1e1e2e", activeforeground="#cdd6f4",
                           command=self._redraw).pack(anchor="w")
        if not MODEL_AVAILABLE:
            tk.Label(opt_frame, text="(no model — train first)", bg="#1e1e2e",
                     fg="#f38ba8", font=("Segoe UI", 8)).pack(anchor="w")

        if MODEL_AVAILABLE:
            tk.Frame(opt_frame, bg="#45475a", height=1).pack(fill=tk.X, pady=(8, 4))
            tk.Checkbutton(opt_frame, text="Sequence constraints\n(Viterbi)",
                           variable=self._use_viterbi,
                           bg="#1e1e2e", fg="#cdd6f4", selectcolor="#313244",
                           activebackground="#1e1e2e", activeforeground="#cdd6f4",
                           justify=tk.LEFT,
                           command=self._rerun_inference).pack(anchor="w")

        # legend
        leg_frame = tk.Frame(left, bg="#1e1e2e")
        leg_frame.pack(fill=tk.X, pady=(12, 0))
        tk.Label(leg_frame, text="Classes", bg="#1e1e2e", fg="#a6adc8",
                 font=("Segoe UI", 9, "bold")).pack(anchor="w")
        for name, color in CLASS_COLORS.items():
            row = tk.Frame(leg_frame, bg="#1e1e2e")
            row.pack(anchor="w", pady=1)
            tk.Label(row, bg=color, width=2, relief=tk.FLAT).pack(side=tk.LEFT, padx=(0, 4))
            tk.Label(row, text=name.replace("_", " "), bg="#1e1e2e",
                     fg="#cdd6f4", font=("Segoe UI", 8)).pack(side=tk.LEFT)

        # right panel
        right = tk.Frame(self, bg="#1e1e2e")
        right.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=10, pady=10)

        plt.style.use("dark_background")
        self.fig, (self.ax_main, self.ax_pred) = plt.subplots(
            2, 1, figsize=(9, 6),
            gridspec_kw={"height_ratios": [4, 1], "hspace": 0.05},
            sharex=True,
        )
        self.fig.patch.set_facecolor("#1e1e2e")
        for ax in (self.ax_main, self.ax_pred):
            ax.set_facecolor("#181825")

        self.canvas = FigureCanvasTkAgg(self.fig, master=right)
        self.canvas.get_tk_widget().pack(fill=tk.BOTH, expand=True)

        tb_frame = tk.Frame(right, bg="#1e1e2e")
        tb_frame.pack(fill=tk.X)
        tb = NavigationToolbar2Tk(self.canvas, tb_frame)
        tb.config(background="#313244")
        tb.update()

        sl_frame = tk.Frame(right, bg="#1e1e2e")
        sl_frame.pack(fill=tk.X, pady=(4, 0))

        info_row = tk.Frame(sl_frame, bg="#1e1e2e")
        info_row.pack(fill=tk.X)
        self._time_label = tk.Label(info_row, text="", bg="#1e1e2e",
                                    fg="#a6adc8", font=("Segoe UI", 9))
        self._time_label.pack(side=tk.LEFT)
        self._bpm_label = tk.Label(info_row, text="", bg="#1e1e2e",
                                   fg="#a6e3a1", font=("Segoe UI", 11, "bold"))
        self._bpm_label.pack(side=tk.RIGHT, padx=(0, 4))

        self._slider = ttk.Scale(sl_frame, orient=tk.HORIZONTAL,
                                 from_=0.0, to=1.0, command=self._on_slide)
        self._slider.pack(fill=tk.X)
        self._slider.state(["disabled"])

        self.ax_main.set_title("Select a file")
        self.ax_main.set_ylabel("Value")
        self.ax_main.grid(True, alpha=0.3)
        self.ax_pred.set_ylabel("Label")
        self.canvas.draw()

    def _populate_list(self):
        for f in sorted(f for f in os.listdir(LABELLED_DIR) if f.endswith(".txt")):
            self.listbox.insert(tk.END, f)

    # ── file selection ────────────────────────────────────────────────────────
    def _on_select(self, _event):
        sel = self.listbox.curselection()
        if not sel:
            return
        self._filename = self.listbox.get(sel[0])
        path = os.path.join(LABELLED_DIR, self._filename)
        self._x, self._y, self._valid, self._true_labels = load_file(path)

        self._pred_labels = (run_inference(self._y, use_viterbi=self._use_viterbi.get())
                             if MODEL_AVAILABLE else None)

        self._x_min, self._x_max = self._x[0], self._x[-1]
        total = self._x_max - self._x_min
        if total > WINDOW_SEC:
            self._slider.config(to=total - WINDOW_SEC)
            self._slider.set(0)
            self._slider.state(["!disabled"])
        else:
            self._slider.config(to=1.0)
            self._slider.set(0)
            self._slider.state(["disabled"])
        self._draw_window(0.0)

    def _on_slide(self, value):
        if self._x is None:
            return
        self._draw_window(float(value))

    def _rerun_inference(self):
        """Re-run inference (with or without Viterbi) and redraw."""
        if self._x is None or not MODEL_AVAILABLE:
            return
        self._pred_labels = run_inference(self._y, use_viterbi=self._use_viterbi.get())
        self._draw_window(self._slider.get())

    def _redraw(self, *_):
        if self._x is not None:
            self._draw_window(self._slider.get())

    # ── drawing ───────────────────────────────────────────────────────────────
    def _draw_window(self, offset):
        win_start = self._x_min + offset
        win_end   = win_start + WINDOW_SEC
        mask = (self._x >= win_start) & (self._x <= win_end)
        xw, yw   = self._x[mask], self._y[mask]
        vw       = self._valid[mask]
        true_w   = self._true_labels[mask]
        pred_w   = self._pred_labels[mask] if self._pred_labels is not None else None

        source = self._color_source.get()
        show_true = source in ("ground_truth", "both")
        show_pred = source in ("predictions", "both") and pred_w is not None

        ax = self.ax_main
        ax.clear()

        # full-height coloured background spans
        if show_true and show_pred:
            # both: truth as faint background, predictions as slightly stronger overlay
            self._draw_spans(ax, xw, true_w, alpha=0.15)
            self._draw_spans(ax, xw, pred_w, alpha=0.28)
        elif show_true:
            self._draw_spans(ax, xw, true_w, alpha=0.30)
        elif show_pred:
            self._draw_spans(ax, xw, pred_w, alpha=0.30)

        # signal line
        if xw.size:
            if np.any(vw):
                ax.plot(xw[vw], yw[vw], color="#cdd6f4", linewidth=1.0,
                        label="signal", zorder=4)
            if np.any(~vw):
                ax.scatter(xw[~vw], yw[~vw], color="#f38ba8", s=6, zorder=5,
                           label="corrupt", alpha=0.7)

        ax.set_xlim(win_start, win_end)
        ax.set_ylim(-1.15, 1.15)
        ax.set_ylabel("Value")
        ax.set_title(self._filename)
        ax.axhline(0, color="#585b70", linewidth=0.5, linestyle="--")
        ax.grid(True, alpha=0.2)

        # cycle markers
        active_labels = pred_w if show_pred else true_w
        if active_labels is not None and xw.size:
            self._draw_cycles(ax, xw, active_labels)

        # legend patches
        patches = [mpatches.Patch(color=c, label=n.replace("_", " "), alpha=0.7)
                   for n, c in CLASS_COLORS.items()]
        ax.legend(handles=patches, loc="upper right", fontsize=7,
                  framealpha=0.4, ncol=2)

        # comparison bar (bottom strip) — always shows both when available
        axp = self.ax_pred
        axp.clear()
        if xw.size:
            if pred_w is not None:
                self._draw_spans(axp, xw, pred_w, alpha=0.85, ymin=0.5, ymax=1.0)
                axp.text(win_start + 0.2, 0.72, "pred", fontsize=7,
                         color="#a6adc8", va="center")
            self._draw_spans(axp, xw, true_w, alpha=0.85, ymin=0.0, ymax=0.45)
            axp.text(win_start + 0.2, 0.22, "true", fontsize=7,
                     color="#a6adc8", va="center")

        axp.set_xlim(win_start, win_end)
        axp.set_ylim(0, 1)
        axp.set_yticks([])
        axp.set_xlabel("Time (s)")
        axp.grid(False)

        self._time_label.config(
            text=f"Window: {win_start:.1f} s – {win_end:.1f} s  "
                 f"(total: {self._x_max - self._x_min:.1f} s)"
        )

        # BPM — use active label source for the current window
        active_labels = pred_w if show_pred else true_w
        bpm = self._calc_bpm(active_labels, win_end - win_start)
        if bpm is not None:
            self._bpm_label.config(text=f"⟳  {bpm:.1f} bpm")
        else:
            self._bpm_label.config(text="")

        self.canvas.draw_idle()

    @staticmethod
    def _calc_bpm(labels: np.ndarray, window_sec: float) -> float | None:
        """Count inhale starts in window → scale to breaths per minute."""
        if labels is None or len(labels) == 0:
            return None
        # an inhale START = index where label switches TO "inhale"
        inhale_starts = sum(
            1 for i in range(1, len(labels))
            if labels[i] == "inhale" and labels[i - 1] != "inhale"
        )
        if inhale_starts == 0:
            return None
        return inhale_starts * (60.0 / window_sec)

    @staticmethod
    def _draw_spans(ax, x, labels, alpha=0.3, ymin=0.0, ymax=1.0):
        if len(x) == 0:
            return
        prev_label = labels[0]
        seg_start  = x[0]
        for i in range(1, len(x)):
            if labels[i] != prev_label:
                if prev_label in CLASS_COLORS:
                    ax.axvspan(seg_start, x[i], ymin=ymin, ymax=ymax,
                               color=CLASS_COLORS[prev_label], alpha=alpha,
                               linewidth=0)
                prev_label = labels[i]
                seg_start  = x[i]
        if prev_label in CLASS_COLORS:
            ax.axvspan(seg_start, x[-1], ymin=ymin, ymax=ymax,
                       color=CLASS_COLORS[prev_label], alpha=alpha,
                       linewidth=0)


    @staticmethod
    def _draw_cycles(ax, x: np.ndarray, labels: np.ndarray):
        """
        Mark complete breathing cycles on ax.
        A cycle starts at each inhale onset and ends just before the next one.
        Draws:
          - vertical dashed line at each cycle start
          - horizontal bracket at y = -1.08 spanning the cycle
          - label "N  X.Xs" (cycle number + duration) centred in bracket
        """
        # find indices where inhale starts
        inhale_starts = [
            i for i in range(1, len(labels))
            if labels[i] == "inhale" and labels[i - 1] != "inhale"
        ]
        # also include index 0 if the window begins mid-inhale
        if len(labels) > 0 and labels[0] == "inhale":
            inhale_starts = [0] + inhale_starts

        if len(inhale_starts) < 1:
            return

        # build cycle boundaries: [start0, start1, ..., end_of_window]
        boundaries = [x[i] for i in inhale_starts] + [x[-1]]

        BRACKET_Y  = -1.08
        TICK_H     = 0.04   # vertical tick height at bracket ends
        COLORS     = ["#a6e3a1", "#89dceb"]   # alternating green / cyan

        for n, (t0, t1) in enumerate(zip(boundaries[:-1], boundaries[1:])):
            duration = t1 - t0
            color    = COLORS[n % 2]

            # vertical line at cycle start
            ax.axvline(t0, color=color, linewidth=0.8,
                       linestyle="--", alpha=0.6, zorder=5)

            # horizontal bracket: left tick + line + right tick
            ax.plot([t0, t1], [BRACKET_Y, BRACKET_Y],
                    color=color, lw=1.2, clip_on=False, zorder=6)
            ax.plot([t0, t0], [BRACKET_Y - TICK_H, BRACKET_Y + TICK_H],
                    color=color, lw=1.2, clip_on=False, zorder=6)
            ax.plot([t1, t1], [BRACKET_Y - TICK_H, BRACKET_Y + TICK_H],
                    color=color, lw=1.2, clip_on=False, zorder=6)

            # label: cycle number + duration
            mid = (t0 + t1) / 2
            ax.text(mid, BRACKET_Y - 0.07,
                    f"#{n + 1}  {duration:.1f}s",
                    ha="center", va="top", fontsize=7,
                    color=color, clip_on=False, zorder=6)


if __name__ == "__main__":
    app = App()
    app.mainloop()
