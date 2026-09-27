#!/usr/bin/env python3
"""Liste les GPU disponibles dans un datacenter RunPod, avec leur stock.

Usage: ./00-check-gpu-availability.py [DATA_CENTER_ID] [filtre_regex_nom]
  ./00-check-gpu-availability.py                     # DATA_CENTER_ID de .env, tous les GPU
  ./00-check-gpu-availability.py US-KS-2             # datacenter explicite, tous les GPU
  ./00-check-gpu-availability.py US-KS-2 "6000|5090" # datacenter + filtre par nom (regex)
"""
import re
import sys

import lib


def main():
    lib.setup()

    dc = sys.argv[1] if len(sys.argv) > 1 else lib.require_env(
        "DATA_CENTER_ID", "Passe un data-center-id en argument, ou renseigne DATA_CENTER_ID dans deploy/.env"
    )
    pattern = sys.argv[2] if len(sys.argv) > 2 else None

    gpus = lib.runpodctl_json("gpu", "list", "--include-unavailable")

    # Un data-center-id invalide/mal orthographié (ex: confondre EU-RO-1 et US-RO-1) donne
    # silencieusement zéro résultat côté API : on le détecte ici pour éviter la confusion.
    valid_dcs = sorted({
        dca["dataCenterId"] for g in gpus for dca in (g.get("dataCenterAvailability") or [])
    })
    if dc not in valid_dcs:
        print(f"!! '{dc}' ne correspond à aucun data-center-id RunPod connu. Datacenters valides :", file=sys.stderr)
        for i in range(0, len(valid_dcs), 6):
            print("  " + "  ".join(valid_dcs[i:i + 6]), file=sys.stderr)
        sys.exit(1)

    regex = re.compile(pattern, re.IGNORECASE) if pattern else None
    label = f" (filtre nom: {pattern})" if pattern else ""
    print(f">> GPU dans {dc}{label} :")

    rows = []
    for g in gpus:
        if regex and not regex.search(g["gpuId"]):
            continue
        for dca in (g.get("dataCenterAvailability") or []):
            if dca["dataCenterId"] != dc:
                continue
            price = g.get("securePricePerHr")
            price_str = f"{price}$/h secure" if price is not None else "n/a"
            rows.append((g["gpuId"], dca["stockStatus"], f"{g['memoryInGb']}GB", price_str))

    if not rows:
        print("  (aucun résultat)")
        return

    widths = [max(len(r[i]) for r in rows) for i in range(4)]
    for r in rows:
        print("  ".join(c.ljust(w) for c, w in zip(r, widths)))


if __name__ == "__main__":
    main()
