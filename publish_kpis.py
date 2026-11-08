#!/usr/bin/env python3
"""
Publie les indicateurs du jour, de la semaine et du mois en cours vers l'espace équipe (table Supabase kpi_feed),
pour les objectifs suivis automatiquement (clés « …@jour » et « …@semaine » à côté de la clé du mois).
Le réalisé vient du journal « Objectifs Palomano Lille » ; les jours pas encore saisis sont complétés
par l'export caisse Qweekle. Cibles du jour et de la semaine : objectif du mois × poids du jour (OBJECTIF JOUR).
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


# ───────────── Réalisé jour par jour : journal « Objectifs Palomano Lille » + export caisse Qweekle ─────────────
SEG = ("ca", "parc", "anniv_ht", "groupes", "snack", "ent", "paying", "anniv_n")


def from_journal(r):
    return {"ca": r[8], "parc": r[1], "anniv_ht": r[2], "groupes": r[3] + r[4], "snack": r[5] + r[6],
            "ent": r[9], "paying": r[12], "anniv_n": r[11], "snack_only": r[5]}


def from_ventes(v):
    """Agrégats journaliers de l'export caisse (montants HT, par date de vente)."""
    out = {}
    for di, p, q, ht in v["pd"]:
        fam, _, name, _ = v["products"][p]
        d = out.setdefault(v["days"][di], dict.fromkeys(SEG + ("snack_only",), 0.0))
        if fam != "autre":                      # acomptes, bons cadeaux, avoirs : pas du CA du jour
            d["ca"] += ht
        if fam == "entrees":
            d["parc"] += ht
            d["paying"] += q
        elif fam == "anniv":
            d["anniv_ht"] += ht
        elif fam == "b2b":
            d["groupes"] += ht
        elif fam in ("snack", "boutique"):
            d["snack"] += ht
            if fam == "snack":
                d["snack_only"] += ht
        if fam in ("entrees", "anniv", "b2b") and not str(name).lower().startswith("anniversaire"):
            d["ent"] += q                       # entrées tous publics (hors ligne « formule anniversaire »)
    for day, t in v.get("tk", {}).items():
        if day in out:
            out[day]["anniv_n"] = t.get("anniv", 0)
    return out


def reconcile(journal, ventes):
    """Écart caisse / journal sur les jours communs du dernier mois saisi (en %, sans montant)."""
    common = sorted(set(journal) & set(ventes))[-31:]
    if not common:
        return
    def pct(k):
        a, b = sum(journal[x][k] for x in common), sum(ventes[x][k] for x in common)
        return f"{k} {b / a * 100:.0f} %" if a else f"{k} —"
    print(f"Contrôle caisse / journal ({common[0]} → {common[-1]}) : " + " · ".join(pct(k) for k in SEG))


def daily_real(d):
    journal = {r[0]: from_journal(r) for r in d["daily"]}
    days, source = dict(journal), {}
    if d.get("ventes"):
        ventes = from_ventes(d["ventes"])
        reconcile(journal, ventes)
        for day, v in ventes.items():
            if day > (d["lastDate"] or ""):     # le journal fait foi ; la caisse complète les jours non saisis
                days[day], source[day] = v, "caisse"
    return days, source


def weights(d):
    raw = {}
    for day, v in d["dayObj"].items():
        raw[day[:7]] = raw.get(day[:7], 0) + v
    def w(day):
        k = day[:7]
        n = (dt.date(int(k[:4]) + int(k[5:]) // 12, int(k[5:]) % 12 + 1, 1) - dt.timedelta(days=1)).day
        return d["dayObj"].get(day, 0) / raw[k] if raw.get(k) else 1 / n
    return w


def span(a, b):
    a, b = dt.date.fromisoformat(a), dt.date.fromisoformat(b)
    return [(a + dt.timedelta(days=i)).isoformat() for i in range((b - a).days + 1)]


def kpis(d):
    days, source = daily_real(d)
    last = max(x for x, v in days.items() if v["ca"] > 0)
    w = weights(d)
    ref = dt.date.fromisoformat(last)
    mon = ref - dt.timedelta(days=ref.weekday())
    periods = {   # (jours réalisés, jours de la cible, libellé)
        "jour": ([last], [last], ref.strftime("%d/%m")),
        "semaine": (span(mon.isoformat(), last), span(mon.isoformat(), (mon + dt.timedelta(days=6)).isoformat()),
                    "semaine du " + mon.strftime("%d/%m")),
        "mois": (span(last[:8] + "01", last), None, ref.strftime("%m/%Y")),
    }
    dist = d["avis"].get("dist") or []
    nb = sum(x["n"] for x in dist)
    note = sum(x["etoiles"] * x["n"] for x in dist) / nb if nb else None
    out = [{"key": "note_google", "label": "Note Google", "value": round(note, 2) if note else None,
            "target": 4.8, "unit": "note", "period": d["avis"].get("releve", "")}]
    for per, (real_days, tgt_days, label) in periods.items():
        sfx = "" if per == "mois" else "@" + per
        if any(source.get(x) for x in real_days):
            label += " · caisse Qweekle"
        tot = lambda k: sum(days[x][k] for x in real_days if x in days)
        k = last[:7]
        if per == "mois":
            ca_t, vis_t = month_target(d, k), month_visitors(d, k)
        else:
            ca_t = sum(month_target(d, x[:7]) * w(x) for x in tgt_days if month_target(d, x[:7]))
            vis_t = sum((month_visitors(d, x[:7]) or 0) * w(x) for x in tgt_days) or None
        n1 = [(dt.date.fromisoformat(x) - dt.timedelta(days=364)).isoformat() for x in real_days]
        anniv1 = sum(days[x]["anniv_n"] for x in n1 if x in days)
        lab = {"jour": " du jour", "semaine": " de la semaine", "mois": " du mois"}[per]
        out += [
            {"key": "entrees_mois" + sfx, "label": f"Entrées{lab} vs objectif", "value": round(tot("ent")),
             "target": round(vis_t) if vis_t else None, "unit": "nb", "period": label},
            {"key": "ca_mois" + sfx, "label": f"Atteinte de l'objectif{lab}",
             "value": round(tot("ca") / ca_t * 100, 1) if ca_t else None, "target": 100, "unit": "%", "period": label},
            {"key": "snack_visiteur" + sfx, "label": f"Snack par visiteur{lab}",
             "value": round(tot("snack_only") / tot("paying"), 2) if tot("paying") else None,
             "target": 1.05, "unit": "€", "period": label},
            {"key": "anniv_mois" + sfx, "label": f"Anniversaires{lab} (vs même période N-1)", "value": round(tot("anniv_n")),
             "target": anniv1 or None, "unit": "nb", "period": label},
        ] + yannika(d, k, tot, label, sfx, None if per == "mois" else tgt_days, w)
    return out


def yannika(d, k, tot, label, sfx, tgt_days, w):
    """Réalisé face aux objectifs du BP de la directrice (€ HT, sauf visiteurs) ; jour et semaine au prorata."""
    R = d["bp"]["rows"]
    def tgt(*keys):
        def month(m):
            return sum((R.get(x) or [0] * 12)[BPM.index(m)] or 0 for x in keys) if m in BPM else 0
        v = month(k) if tgt_days is None else sum(month(x[:7]) * w(x) for x in tgt_days)
        return round(v) or None
    if k not in BPM:
        return []
    out = [  # (clé, libellé, réalisé, cible, unité)
        ("yan_ca", "CA HT", tot("ca"), tgt("ca"), "€"),
        ("yan_visiteurs", "Visiteurs", tot("ent"), tgt("vis"), "nb"),
        ("yan_parc", "CA HT billetterie parc", tot("parc"), tgt("enfants", "adultes"), "€"),
        ("yan_anniv", "CA HT anniversaires", tot("anniv_ht"), tgt("anniv"), "€"),
        ("yan_groupes", "CA HT écoles & centres", tot("groupes"), tgt("ecole", "adl"), "€"),
        ("yan_snack", "CA HT snack & boutique", tot("snack"), tgt("snackbout"), "€"),
    ]
    lab = {"": " du mois", "@jour": " du jour", "@semaine": " de la semaine"}[sfx]
    return [{"key": a + sfx, "label": f"{b}{lab} (objectif Yannika)", "value": round(v), "target": t, "unit": u,
             "period": label, "restricted": True} for a, b, v, t, u in out]


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
    # journal public (dépôt public) : pas de montants, seulement les pourcentages d'atteinte
    print("Espace équipe : " + " · ".join(
        f"{r['key']}={round(r['value'] / r['target'] * 100) if r['value'] is not None and r['target'] else '—'} %"
        for r in rows if r["key"] != "note_google"))
    ensure_yannika_objectives(url, key, [r for r in rows if r["key"].startswith("yan_") and "@" not in r["key"]])


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
