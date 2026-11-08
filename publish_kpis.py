#!/usr/bin/env python3
"""
Publie quelques indicateurs du mois vers l'espace équipe (table Supabase kpi_feed),
pour les objectifs suivis automatiquement. Volumes et pourcentages uniquement :
aucun montant de CA n'est envoyé à l'équipe.

Variables d'environnement : SUPABASE_URL, SUPABASE_SERVICE_KEY (secrets GitHub).
Sans elles, le script ne fait rien.
Usage :  python3 publish_kpis.py   (après build_dashboard.py)
"""
import datetime as dt
import json
import os
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
BPM = ["2026-05", "2026-06", "2026-07", "2026-08", "2026-09", "2026-10",
       "2026-11", "2026-12", "2027-01", "2027-02", "2027-03", "2027-04"]


def month_target(d, k):
    y, m = k[:4], int(k[5:7]) - 1
    if y in d["objCal"]:
        return d["objCal"][y][m] or None
    return d["bp"]["rows"]["ca"][BPM.index(k)] if k in BPM else None


def month_visitors(d, k):
    if k in BPM:
        return d["bp"]["rows"]["vis"][BPM.index(k)]
    return (d["objSeg"].get(k) or {}).get("vis")


def kpis(d):
    last = d["lastDate"]
    k = last[:7]
    rows = [r for r in d["daily"] if r[0].startswith(k)]
    # même mois N-1, à date comparable (J-364)
    a1 = (dt.date.fromisoformat(k + "-01") - dt.timedelta(days=364)).isoformat()
    b1 = (dt.date.fromisoformat(last) - dt.timedelta(days=364)).isoformat()
    n1 = [r for r in d["daily"] if a1 <= r[0] <= b1]
    ca, ent, paying, snack = (sum(r[i] for r in rows) for i in (8, 9, 12, 5))
    anniv, anniv1 = sum(r[11] for r in rows), sum(r[11] for r in n1)
    tgt = month_target(d, k)
    dist = d["avis"].get("dist") or []
    nb = sum(x["n"] for x in dist)
    note = sum(x["etoiles"] * x["n"] for x in dist) / nb if nb else None
    label = dt.date.fromisoformat(last).strftime("%m/%Y")
    return [
        {"key": "entrees_mois", "label": "Entrées du mois vs objectif", "value": ent,
         "target": month_visitors(d, k), "unit": "nb", "period": label},
        {"key": "ca_mois", "label": "Atteinte de l'objectif du mois", "value": round(ca / tgt * 100, 1) if tgt else None,
         "target": 100, "unit": "%", "period": label},
        {"key": "snack_visiteur", "label": "Snack par visiteur", "value": round(snack / paying, 2) if paying else None,
         "target": 1.05, "unit": "€", "period": label},
        {"key": "anniv_mois", "label": "Anniversaires du mois (vs même période N-1)", "value": anniv,
         "target": anniv1 or None, "unit": "nb", "period": label},
        {"key": "note_google", "label": "Note Google", "value": round(note, 2) if note else None,
         "target": 4.8, "unit": "note", "period": d["avis"].get("releve", "")},
    ]


def main():
    url, key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_KEY")
    if not url or not key:
        print("Espace équipe : secrets Supabase absents, indicateurs non publiés")
        return
    d = json.loads((HERE / "data.json").read_text(encoding="utf-8"))
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    rows = [dict(r, updated_at=now) for r in kpis(d)]
    req = urllib.request.Request(
        url.rstrip("/") + "/rest/v1/kpi_feed?on_conflict=key", data=json.dumps(rows).encode(), method="POST",
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json",
                 "Prefer": "resolution=merge-duplicates,return=minimal"})
    try:
        urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as e:
        sys.exit(f"Espace équipe : échec de publication des indicateurs (HTTP {e.code}) {e.read()[:200]!r}")
    print("Espace équipe : " + " · ".join(f"{r['key']}={r['value']}" for r in rows))


if __name__ == "__main__":
    main()
