"""
Viterbi sequence decoder + minimum-duration filter for breathing classification.

Enforces physiologically valid transitions:
  inhale           -> inhale, exhale, retention_inhale
  exhale           -> exhale, inhale, retention_exhale
  retention_inhale -> retention_inhale, exhale
  retention_exhale -> retention_exhale, inhale

And a minimum phase duration (default 0.5 s) — any phase shorter than that
is merged into the surrounding phase.

Class indices (matching train_model.py):
  0 = inhale
  1 = exhale
  2 = retention_inhale
  3 = retention_exhale
"""

import numpy as np

# ── Transition log-probability matrix ────────────────────────────────────────
# 0 = allowed (log prob 0), -1000 = forbidden (log prob -inf approx)
#
#           to:  inh    exh    r_in   r_ex
_TRANSITIONS = np.array([
    # from inhale
    [    0,      0,      0,    -1000],
    # from exhale
    [    0,      0,  -1000,       0],
    # from retention_inhale
    [-1000,      0,      0,   -1000],
    # from retention_exhale
    [    0,  -1000,  -1000,       0],
], dtype=np.float32)

# ── Minimum duration filter ───────────────────────────────────────────────────
SAMPLE_RATE  = 9.8   # Hz — approximate sensor sample rate
MIN_DURATION = 0.5   # seconds — phases shorter than this are removed
MIN_SAMPLES  = int(MIN_DURATION * SAMPLE_RATE)   # = 4 samples


def min_duration_filter(path: np.ndarray, min_samples: int = MIN_SAMPLES) -> np.ndarray:
    """
    Remove phase segments shorter than min_samples by replacing them
    with the label of the preceding segment.

    Example (min_samples=4):
      [0,0,0, 1,1, 0,0,0,0]  →  [0,0,0, 0,0, 0,0,0,0]
              ^^^
           only 2 samples — merged into previous phase (inhale)
    """
    path = path.copy()
    T = len(path)
    i = 0
    while i < T:
        # find end of current segment
        j = i + 1
        while j < T and path[j] == path[i]:
            j += 1
        segment_len = j - i
        if segment_len < min_samples and i > 0:
            # replace segment with the label before it
            path[i:j] = path[i - 1]
        i = j
    return path


def viterbi(log_probs: np.ndarray,
            log_trans: np.ndarray = _TRANSITIONS,
            apply_min_duration: bool = True) -> np.ndarray:
    """
    Viterbi decoding followed by optional minimum-duration filtering.

    Parameters
    ----------
    log_probs          : (T, C) array — log-softmax output from the CNN per frame
    log_trans          : (C, C) array — log transition probabilities [from, to]
    apply_min_duration : if True, run min_duration_filter after Viterbi

    Returns
    -------
    path : (T,) int array — best valid class sequence
    """
    T, C = log_probs.shape
    dp      = np.full((T, C), -np.inf, dtype=np.float64)
    backptr = np.zeros((T, C), dtype=np.int32)

    dp[0] = log_probs[0]

    for t in range(1, T):
        scores     = dp[t - 1, :, None] + log_trans   # (C, C)
        best_prev  = scores.argmax(axis=0)             # (C,)
        dp[t]      = scores[best_prev, np.arange(C)] + log_probs[t]
        backptr[t] = best_prev

    # backtrack
    path = np.empty(T, dtype=np.int32)
    path[T - 1] = dp[T - 1].argmax()
    for t in range(T - 2, -1, -1):
        path[t] = backptr[t + 1, path[t + 1]]

    if apply_min_duration:
        path = min_duration_filter(path)

    return path
