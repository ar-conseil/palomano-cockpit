#!/usr/bin/env python3
"""
Rentabilité mois par mois, à partir de la comptabilité tenue par Rodolph (Supabase) :
  - mois terminés : écritures du grand livre (réel, provisions de Rodolph comprises et signalées) ;
  - mois en cours : écritures déjà passées + CA de la saisie du jour ;
  - mois à venir  : projection du BP (fichier « avec TVA - AVENANT … » déposé chez Rodolph).
Mêmes rubriques que le fichier AVENANT : CA, achats, franchise, intérim, structure, masse salariale → EBE.
Appelé par build_dashboard.py (clé de service Supabase dans le robot GitHub). Sans accès : renvoie None.
"""
import datetime as dt
import json
import os
import urllib.request

RUBRIQUES = ("ca", "achats", "franchise", "interim", "structure", "ms")


def rubrique(compte, plan):
    """Rubrique du BP pour un numéro de compte (d'après les regroupements de l'onglet BDD)."""
    c = str(compte)
    p = plan.get(c) or {}
    r1, r2 = (p.get("rgpmt1") or "").lower(), (p.get("rgpmt2") or "").lower()
    if c.startswith("7"):
        if c.startswith(("706", "707")):
            return "ca"
        if c.startswith("791"):
            return "structure"      # transferts de charges : viennent en déduction des charges
        return None                 # produits financiers / exceptionnels : hors EBE
    if not c.startswith("6"):
        return None
    if c.startswith(("66", "67", "68", "69")):
        return {"66": "fin", "68": "dap"}.get(c[:2])
    if "cogs" in r1 or c.startswith("607"):
        return "achats"
    if "palomano" in r1 or c.startswith(("651", "6281")):
        return "franchise"
    if "animateur" in r2 or "staffeur" in r2 or c.startswith(("6216", "6217")):
        return "interim"
    if "salari" in r1 or c.startswith(("641", "645", "647", "648")):
        return "ms"
    return "structure"


def par_mois(ecritures, plan):
    """{mois: {rubrique: montant (charges en positif), 'provisions': n, 'a_verifier': n, 'n': n}}."""
    out = {}
    for e in ecritures:
        k = e["date"][:7]
        rb = rubrique(e["compte"], plan)
        o = out.setdefault(k, {**{r: 0.0 for r in RUBRIQUES}, "dap": 0.0, "fin": 0.0, "provisions": 0, "a_verifier": 0, "n": 0})
        o["n"] += 1
        if e.get("statut") == "provisoire":
            o["provisions"] += 1
        elif e.get("statut") == "a_verifier":
            o["a_verifier"] += 1
        if not rb:
            continue
        v = float(e["ht"] or 0) * (1 if e["sens"] == "D" else -1)     # charge positive, produit négatif
        o[rb] += -v if rb == "ca" else v
    return out


def mois_bp(debut="2026-05", n=12):
    y, m = int(debut[:4]), int(debut[5:])
    return [f"{y + (m - 1 + i) // 12}-{(m - 1 + i) % 12 + 1:02d}" for i in range(n)]


def calcul(ecritures, plan_list, bp_lignes, journal_ca, aujourd_hui, mois_liste):
    """Assemble les mois de l'exercice. bp_lignes : {mois: {ligne: montant}} (lignes L_* de compta_bp)."""
    plan = {str(p["compte"]): p for p in plan_list}
    reel = par_mois(ecritures, plan)
    cur = aujourd_hui[:7]
    rows = []
    for k in mois_liste:
        b = bp_lignes.get(k, {})
        prev = {r: b.get("L_" + r.upper()) for r in RUBRIQUES}
        a_bp = any(v is not None for v in prev.values())
        r = reel.get(k)
        if k < cur and r and r["n"]:
            etat, src = "reel", r
        elif k == cur:
            etat = "encours"
            src = dict(r) if r else {**{x: 0.0 for x in RUBRIQUES}, "provisions": 0, "a_verifier": 0}
            src["ca"] = journal_ca.get(k, src.get("ca", 0.0))    # CA du mois : saisie du jour, pas encore passé en compta
        elif k < cur and b.get("L_REEL"):
            etat, src = "reel_bp", prev                            # comptabilité pas encore reprise : réel du fichier
        elif a_bp:
            etat, src = "prev", prev
        else:
            etat, src = "vide", {x: None for x in RUBRIQUES}
        o = {"k": k, "etat": etat, **{x: (round(src.get(x) or 0.0, 2) if src.get(x) is not None else None) for x in RUBRIQUES},
             "prov": src.get("provisions", 0) if isinstance(src, dict) else 0,
             "verif": src.get("a_verifier", 0) if isinstance(src, dict) else 0,
             "bp": {x: (round(v, 2) if v is not None else None) for x, v in prev.items()} if a_bp else None}
        if o["ca"] is not None:
            o["charges"] = round(sum(o[x] or 0 for x in RUBRIQUES[1:]), 2)
            o["ebe"] = round(o["ca"] - o["charges"], 2)
        rows.append(o)
    return rows


# ───────────── Lecture Supabase (robot GitHub) ─────────────
def _get(url, key, path):
    out, i = [], 0
    while True:
        req = urllib.request.Request(f"{url}/rest/v1/{path}", headers={"apikey": key, "Authorization": f"Bearer {key}",
                                                                      "Range-Unit": "items", "Range": f"{i}-{i + 999}"})
        with urllib.request.urlopen(req, timeout=60) as r:
            part = json.load(r)
        out += part
        if len(part) < 1000:
            return out
        i += 1000


def depuis_supabase(data):
    url, key = os.environ.get("SUPABASE_URL", "").rstrip("/"), os.environ.get("SUPABASE_SERVICE_KEY", "")
    if not url or not key:
        return None
    try:
        mois = mois_bp()
        ecr = _get(url, key, f"compta_ecritures?select=date,compte,sens,ht,statut&date=gte.{mois[0]}-01&date=lte.{mois[-1]}-31")
        plan = _get(url, key, "compta_plan?select=compte,rgpmt1,rgpmt2")
        bpl = {}
        for x in _get(url, key, "compta_bp?select=mois,ligne,montant&ligne=like.L_*"):
            bpl.setdefault(x["mois"], {})[x["ligne"]] = float(x["montant"]) if x["montant"] is not None else None
        etat = _get(url, key, "sync_state?select=ok,message,synced_at&key=eq.rodolph")
    except Exception as e:     # schéma absent, réseau… : la page garde l'ancienne vue
        print("Rentabilité : comptabilité de Rodolph illisible —", e)
        return None
    if not ecr and not bpl:
        return {"rows": [], "vide": True, "rodolph": etat[0] if etat else None}
    jca = {}
    for r in data["daily"]:
        jca[r[0][:7]] = jca.get(r[0][:7], 0.0) + float(r[8] or 0)
    today = dt.date.today().isoformat()
    return {"rows": calcul(ecr, plan, bpl, jca, today, mois), "vide": False, "rodolph": etat[0] if etat else None,
            "maj": dt.datetime.now().isoformat(timespec="minutes")}


if __name__ == "__main__":   # vérification locale : écritures du LPP regroupées comme le fichier AVENANT
    import sys
    import rodolph_excel as X
    k, wbv, _ = X.lire(sys.argv[1])
    plan = {p["compte"]: p for p in X.plan(wbv)}
    for m, o in sorted(par_mois(X.grand_livre(wbv, 2026), plan).items()):
        ebe = o["ca"] - sum(o[r] for r in RUBRIQUES[1:])
        print(m, *(f"{o[r]:9.0f}" for r in RUBRIQUES), f"EBE {ebe:9.0f}", f"DAP {o['dap']:6.0f} fin {o['fin']:6.0f}")
