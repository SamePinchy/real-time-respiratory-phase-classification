import 'dart:math' as math;

/// Allowed transitions between breathing phases.
/// Row = from-class, column = to-class.
/// 0 = allowed, -1000 = forbidden.
///
/// Classes:  0=inhale  1=exhale  2=retention_inhale  3=retention_exhale
const List<List<double>> _kTransitions = [
  //  inh    exh    r_in    r_ex
  [0,      0,     0,     -1000],  // from inhale
  [0,      0,    -1000,   0   ],  // from exhale
  [-1000,  0,     0,     -1000],  // from retention_inhale
  [0,     -1000, -1000,   0   ],  // from retention_exhale
];

const int _kClasses = 4;

/// Minimum phase duration in samples (~9.8 Hz → 5 samples ≈ 0.5 s).
const int kMinDurationSamples = 5;

/// Viterbi decoding over a sequence of per-frame log-probabilities.
///
/// [logProbs] — list of T frames, each a list of C log-probabilities.
/// Returns the best valid class-index sequence of length T.
List<int> viterbi(List<List<double>> logProbs) {
  final T = logProbs.length;
  if (T == 0) return [];

  // dp[t][c]      — best log-prob ending at class c at time t
  // backptr[t][c] — which previous class led to that best score
  final dp      = List.generate(T, (_) => List.filled(_kClasses, double.negativeInfinity));
  final backptr = List.generate(T, (_) => List.filled(_kClasses, 0));

  for (int c = 0; c < _kClasses; c++) {
    dp[0][c] = logProbs[0][c];
  }

  for (int t = 1; t < T; t++) {
    for (int c = 0; c < _kClasses; c++) {
      double best = double.negativeInfinity;
      int bestPrev = 0;
      for (int prev = 0; prev < _kClasses; prev++) {
        final score = dp[t - 1][prev] + _kTransitions[prev][c];
        if (score > best) {
          best = score;
          bestPrev = prev;
        }
      }
      dp[t][c] = best + logProbs[t][c];
      backptr[t][c] = bestPrev;
    }
  }

  // Find best final state
  final path = List.filled(T, 0);
  double bestFinal = double.negativeInfinity;
  for (int c = 0; c < _kClasses; c++) {
    if (dp[T - 1][c] > bestFinal) {
      bestFinal = dp[T - 1][c];
      path[T - 1] = c;
    }
  }

  // Backtrack
  for (int t = T - 2; t >= 0; t--) {
    path[t] = backptr[t + 1][path[t + 1]];
  }

  return path;
}

/// Remove segments shorter than [minSamples] by replacing them
/// with the label of the preceding segment.
List<int> minDurationFilter(List<int> path, {int minSamples = kMinDurationSamples}) {
  if (path.isEmpty) return path;
  final result = List<int>.from(path);
  int i = 0;
  while (i < result.length) {
    int j = i + 1;
    while (j < result.length && result[j] == result[i]) j++;
    final segLen = j - i;
    if (segLen < minSamples && i > 0) {
      for (int k = i; k < j; k++) {
        result[k] = result[i - 1];
      }
    }
    i = j;
  }
  return result;
}

/// Compute log-softmax of raw logits.
List<double> logSoftmax(List<double> logits) {
  final maxVal = logits.reduce(math.max);
  final exps   = logits.map((v) => math.exp(v - maxVal)).toList();
  final sumExp = exps.reduce((a, b) => a + b);
  return exps.map((v) => math.log(v / sumExp)).toList();
}
