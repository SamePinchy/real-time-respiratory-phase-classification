#!/usr/bin/env python3
"""
Przygotowanie nowego nagrania do zbioru uczacego.

Wejscie:  wyeksportowany z aplikacji plik TXT (Timestamp, Raw, Stretch[%], Phase)
Wyjscie:  plik w formacie katalogu mylabels — wartosc, etykieta, czas [s]
          oraz raport porownujacy profil sygnalu z profilem zbioru uczacego

Przebieg:
  1. sygnal w skali procentowej (po kalibracji kroczacej wykonanej przez aplikacje)
     przeliczany jest na dziedzine [-1, 1] odwzorowaniem zakotwiczonym na zmierzonym
     poziomie spoczynkowym nagrania, tak aby spoczynek trafil na -0,956 —
     czyli tam, gdzie lezy w dotychczasowym zbiorze uczacym;
  2. na znormalizowanym sygnale uruchamiana jest regula progowa z autolabel2.py,
     ktora daje etykiety poczatkowe do recznej korekty.

Uzycie:
    python przygotuj_nagranie_uczace.py nagranie.txt tens_manual.txt
    python przygotuj_nagranie_uczace.py nagranie.txt tens_manual.txt --z-raw

Przelacznik --z-raw wyznacza zakres roboczy samodzielnie z kolumny Raw, kalibracja
kroczaca liczona jest wtedy w skrypcie. Domyslnie uzywana jest kolumna Stretch[%],
w ktorej aplikacja juz to zrobila.

Wymaga: numpy
"""

import argparse
import os
import sys
from datetime import datetime

import numpy as np

# ── Parametry zgodne z aplikacja i potokiem uczenia ──────────────────────────
POZIOM_UCZACY = -0.956        # poziom spoczynkowy w dotychczasowym zbiorze
SMOOTH_WINDOW, DERIV_THR, FLAT_THR = 5, 0.0079, 0.0

# kalibracja kroczaca (uzywana tylko przy --z-raw)
OKNO_KALIBRACJI = 120
ROZGRZEWKA = 60
CO_ILE = 10
ZAPAS = 0.10
MIN_ROZPIETOSC = 3000
BAZA_PROC = 20.0

# nazwy faz z kolumny Phase w eksporcie -> wskazniki w formacie mylabels
MAPA_FAZ = {
    "wdech": 1.0,
    "wydech": -1.0,
    "zatrzymanie (wdech)": 2.0,
    "zatrzymanie (wydech)": 0.0,
}

# profil dotychczasowego zbioru uczacego — do kontroli
PROFIL_NASYCENIE_DOL = (2.4, 8.1)
PROFIL_NASYCENIE_GORA = (1.2, 3.8)


def wczytaj_tekst(path):
    with open(path, "rb") as f:
        surowe = f.read()
    if surowe[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return surowe.decode("utf-16", errors="replace")
    probka = surowe[:4000]
    if probka.count(0) > len(probka) // 4:
        kod = "utf-16-be" if probka[0::2].count(0) > probka[1::2].count(0) else "utf-16-le"
        return surowe.decode(kod, errors="replace")
    return surowe.decode("utf-8", errors="replace")


def wczytaj_nagranie(path):
    czas, raw, stretch, faza = [], [], [], []
    for line in wczytaj_tekst(path).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("Timestamp"):
            continue
        pola = line.split("\t")
        if len(pola) < 4:
            continue
        try:
            t = datetime.strptime(pola[0], "%Y-%m-%d %H:%M:%S.%f")
        except ValueError:
            continue
        try:
            r = float(pola[1])
        except ValueError:
            r = np.nan
        try:
            s = float(pola[2])
        except ValueError:
            continue
        czas.append(t)
        raw.append(r)
        stretch.append(s)
        faza.append(MAPA_FAZ.get(pola[3].strip().lower(), np.nan))
    if not czas:
        return None, None, None, None
    t0 = czas[0]
    return (np.array([(t - t0).total_seconds() for t in czas]),
            np.array(raw, dtype=np.float64),
            np.array(stretch, dtype=np.float64),
            np.array(faza, dtype=np.float64))


def kalibracja_kroczaca(raw):
    """Odtwarza wyznaczanie zakresu roboczego z aplikacji i zwraca skale procentowa."""
    proc = np.full(len(raw), np.nan)
    lo = hi = None
    for i in range(len(raw)):
        if i >= ROZGRZEWKA and (i - ROZGRZEWKA) % CO_ILE == 0:
            okno = raw[max(0, i - OKNO_KALIBRACJI + 1): i + 1]
            okno = okno[np.isfinite(okno)]
            if len(okno) >= 2:
                a, b = float(okno.min()), float(okno.max())
                rozpietosc = b - a
                if rozpietosc >= MIN_ROZPIETOSC:
                    margines = rozpietosc * ZAPAS
                    lo, hi = a - margines, b + margines
        if lo is None or hi is None or hi <= lo:
            continue
        proc[i] = np.clip((raw[i] - lo) / (hi - lo) * 100.0, 0.0, 100.0)
    return proc


def regula_progowa_wskazniki(y):
    """Zwraca wskazniki w kodowaniu plikow mylabels: 1, -1, 2, 0."""
    smoothed = np.convolve(y, np.ones(SMOOTH_WINDOW) / SMOOTH_WINDOW, mode="same")
    deriv = np.gradient(smoothed)
    return np.where(np.abs(deriv) < DERIV_THR,
                    np.where(smoothed > FLAT_THR, 2.0, 0.0),
                    np.where(deriv > 0, 1.0, -1.0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wejscie", help="wyeksportowany plik TXT z aplikacji")
    ap.add_argument("wyjscie", help="plik wynikowy w formacie mylabels")
    ap.add_argument("--z-raw", action="store_true",
                    help="wyznacz skale procentowa samodzielnie z kolumny Raw")
    ap.add_argument("--pomin-s", type=float, default=0.0,
                    help="pomin poczatkowe sekundy nagrania (rozgrzewka kalibracji)")
    ap.add_argument("--etykiety-z-modelu", action="store_true",
                    help="jako etykiety poczatkowe wez wskazania aplikacji "
                         "z kolumny Phase zamiast wynikow reguly progowej")
    ap.add_argument("--nasycenie-docelowe", type=float, default=None,
                    help="dobierz kotwice tak, aby udzial probek nasyconych przy -1 "
                         "wyniosl podana wartosc w procentach (np. 5.0)")
    args = ap.parse_args()

    if not os.path.exists(args.wejscie):
        print(f"Nie znaleziono pliku {args.wejscie}")
        sys.exit(1)

    t, raw, stretch, faza = wczytaj_nagranie(args.wejscie)
    if t is None:
        print("Nie udalo sie odczytac danych.")
        sys.exit(1)

    print(f"Plik: {os.path.basename(args.wejscie)}")
    print(f"  probek {len(t)}, dlugosc {t[-1] / 60:.2f} min, "
          f"czestotliwosc {len(t) / t[-1]:.2f} Hz")

    if args.z_raw:
        if not np.isfinite(raw).any():
            print("Kolumna Raw jest pusta — nie mozna uzyc --z-raw.")
            sys.exit(1)
        proc = kalibracja_kroczaca(raw)
        print("  skala procentowa wyznaczona z kolumny Raw (kalibracja krocząca)")
    else:
        proc = stretch
        print("  uzyta kolumna Stretch[%] (kalibracja wykonana przez aplikacje)")

    maska = np.isfinite(proc) & (t >= args.pomin_s)
    t, proc, faza = t[maska], proc[maska], faza[maska]
    t = t - t[0]
    print(f"  probek po odrzuceniu niepelnych: {len(proc)}")

    # poziom spoczynkowy wyznaczany na sygnale nieobcietym
    wstepne = regula_progowa_wskazniki(np.clip(proc / 50.0 - 1.0, -1.0, 1.0))
    spocz = proc[wstepne == 0.0]
    poziom = float(np.median(spocz)) if len(spocz) > 20 else float(np.percentile(proc, 10))

    poziom_wyjsciowy = poziom
    if args.nasycenie_docelowe is not None:
        # kotwica obnizana dopoki udzial probek nasyconych nie spadnie do celu
        kandydaci = np.linspace(poziom, max(np.percentile(proc, 0.5), 0.0), 400)
        for kand in kandydaci:
            aa = (1.0 - POZIOM_UCZACY) / (100.0 - kand)
            bb = POZIOM_UCZACY - aa * kand
            if 100 * np.mean(np.clip(aa * proc + bb, -1, 1) <= -0.999) \
                    <= args.nasycenie_docelowe:
                poziom = float(kand)
                break

    a = (1.0 - POZIOM_UCZACY) / (100.0 - poziom)
    b = POZIOM_UCZACY - a * poziom
    x = np.clip(a * proc + b, -1.0, 1.0)

    print(f"\nODWZOROWANIE NA DZIEDZINE UCZENIA")
    print(f"  zmierzony poziom spoczynkowy   {poziom_wyjsciowy:.2f} % skali")
    if args.nasycenie_docelowe is not None and poziom != poziom_wyjsciowy:
        print(f"  kotwica obnizona do            {poziom:.2f} % skali "
              f"(cel nasycenia {args.nasycenie_docelowe:.1f} %)")
    print(f"  a = {a:.6f},  b = {b:.6f}")
    print(f"  kontrola: {poziom:.1f} % -> {a * poziom + b:+.3f}   "
          f"100 % -> {a * 100 + b:+.3f}")

    nas_dol = 100 * np.mean(x <= -0.999)
    nas_gora = 100 * np.mean(x >= 0.999)
    print(f"\nPROFIL SYGNALU WOBEC ZBIORU UCZACEGO")
    print(f"  nasycenie przy -1   {nas_dol:5.2f} %   "
          f"(zbior uczacy: {PROFIL_NASYCENIE_DOL[0]}-{PROFIL_NASYCENIE_DOL[1]} %)"
          f"{'  OK' if PROFIL_NASYCENIE_DOL[0] <= nas_dol <= PROFIL_NASYCENIE_DOL[1] else '  <-- poza zakresem'}")
    print(f"  nasycenie przy +1   {nas_gora:5.2f} %   "
          f"(zbior uczacy: {PROFIL_NASYCENIE_GORA[0]}-{PROFIL_NASYCENIE_GORA[1]} %)"
          f"{'  OK' if PROFIL_NASYCENIE_GORA[0] <= nas_gora <= PROFIL_NASYCENIE_GORA[1] else '  <-- poza zakresem'}")
    print(f"  mediana sygnalu     {np.median(x):+.3f}   (zbior uczacy: ok. -0,25)")

    z_reguly = regula_progowa_wskazniki(x)
    if args.etykiety_z_modelu:
        brak = ~np.isfinite(faza)
        wskazniki = np.where(brak, z_reguly, np.nan_to_num(faza, nan=0.0))
        zrodlo = "wskazania aplikacji"
        print(f"\n  probek bez wskazania aplikacji: {int(brak.sum())} "
              f"({100 * brak.mean():.2f} %) — uzupelnione regula progowa")
        print(f"  zgodnosc wskazan aplikacji z regula: "
              f"{100 * np.mean(wskazniki[~brak] == z_reguly[~brak]):.2f} %")
    else:
        wskazniki = z_reguly
        zrodlo = "regula progowa"

    nazwy = {1.0: "wdech", -1.0: "wydech", 2.0: "retencja po wdechu",
             0.0: "retencja po wydechu"}
    print(f"\nROZKLAD ETYKIET POCZATKOWYCH ({zrodlo})")
    for w in (1.0, -1.0, 2.0, 0.0):
        ile = int(np.sum(wskazniki == w))
        print(f"  {nazwy[w]:24s} {ile:6d}  ({100 * ile / len(wskazniki):5.2f} %)")

    odcinki = np.flatnonzero(np.diff(wskazniki)) + 1
    print(f"  odcinkow faz: {len(odcinki) + 1}")

    with open(args.wyjscie, "w", encoding="utf-8") as f:
        for wart, wsk, czas in zip(x, wskazniki, t):
            f.write(f"{wart:.18f},{wsk:.18f},{czas:.6f}\n")
    print(f"\nZapisano: {args.wyjscie}  ({len(x)} wierszy)")
    print("Plik ma format zgodny z katalogiem mylabels: wartosc, etykieta, czas [s].")
    print(f"Etykiety poczatkowe: {zrodlo}. Sa punktem wyjscia do recznej korekty.")


if __name__ == "__main__":
    main()