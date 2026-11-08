#!/usr/bin/env python3
"""
Publie les indicateurs du mois vers l'espace équipe (table Supabase kpi_feed),
pour les objectifs suivis automatiquement.
- Indicateurs d'équipe : volumes et pourcentages uniquement, sans montant de CA.
- Objectifs mensuels de la directrice (fichier « Objectifs Yannika ») : montants en € HT,
  marqués « restricted » donc lisibles seulement par la direction et les responsables.

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
    ] + yannika(d, k, rows, label)


def yannika(d, k, rows, label):
    """Réalisé du mois face aux objectifs mensuels du BP de la directrice (€ HT, sauf visiteurs)."""
    if k not in BPM:
        return []
    i, R = BPM.index(k), d["bp"]["rows"]
    tgt = lambda *keys: round(sum((R.get(x) or [0] * 12)[i] or 0 for x in keys)) or None
    real = lambda *idx: round(sum(r[j] for r in rows for j in idx))
    out = [  # (clé, libellé, réalisé, cible, unité)
        ("yan_ca", "CA HT du mois (objectif Yannika)", real(8), tgt("ca"), "€"),
        ("yan_visiteurs", "Visiteurs du mois (objectif Yannika)", real(9), tgt("vis"), "nb"),
        ("yan_parc", "CA HT billetterie parc (objectif Yannika)", real(1), tgt("enfants", "adultes"), "€"),
        ("yan_anniv", "CA HT anniversaires (objectif Yannika)", real(2), tgt("anniv"), "€"),
        ("yan_groupes", "CA HT écoles & centres (objectif Yannika)", real(3, 4), tgt("ecole", "adl"), "€"),
        ("yan_snack", "CA HT snack & boutique (objectif Yannika)", real(5, 6), tgt("snackbout"), "€"),
    ]
    return [{"key": a, "label": b, "value": v, "target": t, "unit": u, "period": label, "restricted": True}
            for a, b, v, t, u in out]


def main():
    url, key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_KEY")
    if not url or not key:
        print("Espace équipe : secrets Supabase absents, indicateurs non publiés")
        return
    d = json.loads((HERE / "data.json").read_text(encoding="utf-8"))
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    rows = [dict({"restricted": False}, **r, updated_at=now) for r in kpis(d)]
    req = urllib.request.Request(
        url.rstrip("/") + "/rest/v1/kpi_feed?on_conflict=key", data=json.dumps(rows).encode(), method="POST",
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json",
                 "Prefer": "resolution=merge-duplicates,return=minimal"})
    try:
        urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as e:
        sys.exit(f"Espace équipe : échec de publication des indicateurs (HTTP {e.code}) {e.read()[:200]!r}")
    print("Espace équipe : " + " · ".join(f"{r['key']}={r['value']}" for r in rows))
    ensure_yannika_objectives(url, key, [r for r in rows if r["key"].startswith("yan_")])


def rest(url, key, path, body=None, method="GET"):
    req = urllib.request.Request(url.rstrip("/") + "/rest/v1/" + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"apikey": key, "Authorization": f"Bearer {key}",
                                          "Content-Type": "application/json", "Prefer": "return=minimal"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or "null")


def ensure_yannika_objectives(url, key, yan):
    """Crée une fois les objectifs mensuels de la directrice, dès qu'elle a un compte (yannika.zoa-tsama@palomano.com)."""
    if not yan:
        return
    try:
        who = rest(url, key, "profiles?select=id&email=eq.yannika.zoa-tsama@palomano.com&active=is.true")
        if not who:
            return
        uid = who[0]["id"]
        have = {o["kpi_key"] for o in rest(url, key, f"objectives?select=kpi_key&user_id=eq.{uid}&kpi_key=like.yan_*")}
        new = [{"title": r["label"].replace(" (objectif Yannika)", ""), "scope": "individuel", "user_id": uid,
                "kpi_key": r["key"], "unit": r["unit"], "description": "Objectif mensuel du BP, mis à jour chaque jour"}
               for r in yan if r["key"] not in have]
        if new:
            rest(url, key, "objectives", new, "POST")
            print(f"Espace équipe : {len(new)} objectifs mensuels créés pour Yannika")
    except urllib.error.HTTPError as e:
        print(f"::warning::Objectifs Yannika non créés (HTTP {e.code})")


if __name__ == "__main__":
    main()
