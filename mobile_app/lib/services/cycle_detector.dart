// lib/services/cycle_detector.dart
//
// Wspolna regula wyznaczania poczatkow cykli oddechowych.
// Uzywana przez BreathProvider (rytm biezacy), BreathChart (linie cykli)
// oraz BreathSession (liczba cykli i rytm sesji), dzieki czemu wszystkie
// trzy miejsca licza cykle identycznie.
//
// Kandydatem na poczatek cyklu jest kazde przejscie do fazy wdechu.
// Kandydat jest akceptowany tylko wtedy, gdy wypada na poziomie rozciagniecia
// zblizonym do poziomu poprzednich zaakceptowanych poczatkow:
//
//     v <= ref + tolerance * (peak - ref)
//
// ref  - mediana poziomow ostatnich [levelMemory] zaakceptowanych poczatkow,
// peak - maksimum sygnalu od ostatniego zaakceptowanego poczatku.
//
// Drugi etap wdechu dwufazowego zaczyna sie wysoko (blisko peak), wiec zostaje
// odrzucony. Nowy cykl zostanie przyjety dopiero po wydechu do poziomu
// zblizonego do poprzedniego poczatku.
//
// Zabezpieczenie: jesli od ostatniego zaakceptowanego poczatku minelo wiecej
// niz [maxGapSamples] probek, kolejny kandydat jest przyjmowany bezwarunkowo,
// a referencja jest ustawiana od nowa. Chroni to przed zablokowaniem
// detekcji po trwalym przesunieciu poziomu (np. poprawienie pasa).

/// Zwraca indeksy probek, w ktorych zaczynaja sie zaakceptowane cykle.
List<int> detectCycleStarts({
  required int length,
  required double Function(int i) valueAt,
  required bool Function(int i) isInhaleAt,
  double tolerance = 0.25,
  int levelMemory = 5,
  int maxGapSamples = 150, // ~15 s przy 10 Hz
}) {
  final starts = <int>[];
  final levels = <double>[];
  double peak = double.negativeInfinity;

  for (int i = 0; i < length; i++) {
    final v = valueAt(i);
    if (starts.isNotEmpty && v > peak) peak = v;

    final isOnset = isInhaleAt(i) && (i == 0 || !isInhaleAt(i - 1));
    if (!isOnset) continue;

    bool accept;
    if (starts.isEmpty) {
      accept = true;
    } else if (i - starts.last > maxGapSamples) {
      accept = true;
      levels.clear(); // nowa referencja po dlugiej przerwie
    } else {
      final ref = _medianOfLast(levels, levelMemory);
      final amplitude = peak - ref;
      accept = amplitude > 0 && v <= ref + tolerance * amplitude;
    }

    if (accept) {
      starts.add(i);
      levels.add(v);
      peak = v;
    }
  }
  return starts;
}

double _medianOfLast(List<double> values, int count) {
  final start = values.length > count ? values.length - count : 0;
  final recent = List<double>.from(values.sublist(start))..sort();
  final mid = recent.length ~/ 2;
  return recent.length.isOdd
      ? recent[mid]
      : (recent[mid - 1] + recent[mid]) / 2;
}
