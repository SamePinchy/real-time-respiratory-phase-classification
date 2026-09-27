import tkinter as tk

CYKLE = 20

etapy = [
    ("WDECH", 4, "#4CAF50"),
    ("ZATRZYMAJ\npełne płuca", 3, "#FFC107"),
    ("WYDECH", 4, "#2196F3"),
    ("ZATRZYMAJ\npuste płuca", 3, "#9C27B0"),
]

cykl = 1
etap_index = 0
pozostalo = etapy[0][1]
uruchomiony = False


def start():
    global cykl, etap_index, pozostalo, uruchomiony

    if uruchomiony:
        return

    cykl = 1
    etap_index = 0
    pozostalo = etapy[0][1]
    uruchomiony = True

    przycisk_start.pack_forget()
    aktualizuj()


def aktualizuj():
    global cykl, etap_index, pozostalo, uruchomiony

    nazwa, czas, kolor = etapy[etap_index]

    root.config(bg=kolor)
    label_cykl.config(
        text=f"Cykl {cykl} / {CYKLE}",
        bg=kolor
    )
    label_etap.config(
        text=nazwa,
        bg=kolor
    )
    label_czas.config(
        text=str(pozostalo),
        bg=kolor
    )

    if pozostalo > 1:
        pozostalo -= 1
        root.after(1000, aktualizuj)
        return

    etap_index += 1

    if etap_index >= len(etapy):
        etap_index = 0
        cykl += 1

    if cykl > CYKLE:
        uruchomiony = False

        root.config(bg="#222222")
        label_cykl.config(text="20 / 20", bg="#222222")
        label_etap.config(text="KONIEC", bg="#222222")
        label_czas.config(text="", bg="#222222")

        przycisk_start.config(text="URUCHOM PONOWNIE")
        przycisk_start.pack(pady=20)
        return

    pozostalo = etapy[etap_index][1]
    root.after(1000, aktualizuj)


root = tk.Tk()
root.title("Metronom oddechowy")
root.geometry("600x450")
root.config(bg="#222222")

label_cykl = tk.Label(
    root,
    text="",
    font=("Arial", 22),
    fg="white",
    bg="#222222"
)
label_cykl.pack(pady=(40, 20))

label_etap = tk.Label(
    root,
    text="Gotowy?",
    font=("Arial", 38, "bold"),
    fg="white",
    bg="#222222"
)
label_etap.pack(pady=20)

label_czas = tk.Label(
    root,
    text="",
    font=("Arial", 80, "bold"),
    fg="white",
    bg="#222222"
)
label_czas.pack()

przycisk_start = tk.Button(
    root,
    text="START",
    command=start,
    font=("Arial", 24, "bold"),
    width=12,
    height=2
)
przycisk_start.pack(pady=30)

root.mainloop()