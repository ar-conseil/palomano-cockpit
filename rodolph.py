#!/usr/bin/env python3
"""
Rodolph — agent financier de Palomano Lille. Tient seul la comptabilité de gestion (Supabase) :

  1. Dépôts       fichiers Excel déposés dans Comptabilité › Transmission (stockage factures/rodolph/depot/) :
                  « 2026 LPP PALOMANO LILLE » → grand livre + plan de comptes (reprise, remplace le grand livre)
                  « … avec TVA - AVENANT … »  → business plan ligne par ligne (projection des mois à venir)
  2. E-mails      factures, bulletins / journal de paie, cotisations URSSAF (cabinet de paie, cabinet Pansard) :
                  lus par Claude et passés en écritures (agent_factures.py)
  3. Banque       lignes des relevés CIC importés : rapprochées des écritures ; les lignes sans pièce
                  (URSSAF, salaires, frais bancaires, abonnements…) sont passées d'après les règles, sinon par
                  Claude, « à vérifier »
  4. Provisions   charges récurrentes pas encore arrivées (loyer, assurances, honoraires, salaires…) provisionnées
                  pour le mois précédent et le mois en cours ; la vraie pièce les remplace
  5. CA           chaque mois terminé : CA de la saisie du jour passé en écritures (option --ca, après le build)

Rien n'est payé, envoyé ni supprimé hors de la comptabilité : Rodolph lit et enregistre.
Variables : SUPABASE_URL, SUPABASE_SERVICE_KEY, ANTHROPIC_API_KEY, connexion Microsoft (voir agent_factures.py).
Usage : python3 rodolph.py          (dépôts, e-mails, banque, provisions)
        python3 rodolph.py --ca     (CA des mois terminés, après build_dashboard.py qui écrit data.json)
"""
import datetime as dt
import json
import os
import re
import statistics
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import agent_factures as af
import rodolph_excel as X

HERE = Path(__file__).resolve().parent
SB_URL, SB_KEY = af.SB_URL, af.SB_KEY
PROV_TAG = "Provision Rodolph"
journal = []          # ce que Rodolph a fait pendant ce passage (affiché dans Comptabilité)


def note(txt):
    journal.append(txt)
    print("Rodolph :", txt)


def etat(ok, msg):
    af.sb("sync_state?on_conflict=key", [{"key": "rodolph", "ok": ok, "message": msg[:1500],
                                          "synced_at": dt.datetime.now(dt.timezone.utc).isoformat()}],
          "POST", "resolution=merge-duplicates,return=minimal")


def today():
    return dt.datetime.now(dt.timezone(dt.timedelta(hours=1))).date()


def fin_mois(k):
    y, m = int(k[:4]), int(k[5:7])
    return (dt.date(y + m // 12, m % 12 + 1, 1) - dt.timedelta(days=1)).isoformat()


def mois_moins(k, n):
    y, m = int(k[:4]), int(k[5:7]) - n
    while m < 1:
        y, m = y - 1, m + 12
    return f"{y}-{m:02d}"


def ecritures(depuis="2025-01-01"):
    return af.sb_all("compta_ecritures?select=id,date,compte,fournisseur,libelle,taux,sens,ht,tva,statut,source,commentaire,piece_id"
                     f"&date=gte.{depuis}&order=date")


def insert(rows):
    out = []
    for i in range(0, len(rows), 500):
        out += af.sb("compta_ecritures", rows[i:i + 500], "POST", "return=representation") or []
    return out


def delete_ids(ids):
    ids = list(ids)
    for i in range(0, len(ids), 200):
        af.sb("compta_ecritures?id=in.(" + ",".join(str(x) for x in ids[i:i + 200]) + ")", method="DELETE")


# ───────────── 1. Fichiers déposés ─────────────
def storage(method, path, body=None, raw=False):
    req = urllib.request.Request(f"{SB_URL}/storage/v1/{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
        return data if raw else (json.loads(data) if data else None)


def depots():
    try:
        files = storage("POST", "object/list/factures", {"prefix": "rodolph/depot", "limit": 50,
                                                         "sortBy": {"column": "created_at", "order": "asc"}}) or []
    except urllib.error.HTTPError as e:
        note(f"dossier de dépôt illisible ({e.code})")
        return
    for f in files:
        if not f.get("name") or not f.get("id"):
            continue
        src = f"rodolph/depot/{f['name']}"
        data = storage("GET", "object/factures/" + urllib.parse.quote(src), raw=True)
        try:
            kind, wbv, wbf = X.lire(data)
            if kind == "grand_livre":
                reprise_grand_livre(wbv, f["name"])
            elif kind == "bp":
                reprise_bp(wbv, wbf, f["name"])
            else:
                note(f"« {f['name']} » : ni grand livre (onglet GRAND LIVRE) ni BP (onglets Projection) — ignoré")
        except Exception as e:      # un fichier illisible ne bloque pas le reste
            note(f"« {f['name']} » illisible : {e}")
        storage("POST", "object/move", {"bucketId": "factures", "sourceKey": src,
                                         "destinationKey": f"rodolph/traite/{today().isoformat()}-{f['name']}"})


def reprise_grand_livre(wbv, nom):
    rows = X.grand_livre(wbv)
    if not rows:
        return note(f"« {nom} » : aucune écriture lue")
    from collections import Counter
    an = Counter(r["date"][:4] for r in rows).most_common(1)[0][0]
    bizarres = [r for r in rows if r["date"][:4] != an]
    rows = [r for r in rows if r["date"][:4] == an]
    if bizarres:
        note(f"⚠ {len(bizarres)} ligne(s) du grand livre avec une date hors {an}, non reprises : "
             + " ; ".join(f"{r['date']} {r['fournisseur']} {r['libelle'][:30]} {r['ht']:.2f} €" for r in bizarres[:5]))
    plan = X.plan(wbv)
    if plan:
        af.sb("compta_plan?on_conflict=compte", plan, "POST", "resolution=merge-duplicates,return=minimal")
    annees = sorted({r["date"][:4] for r in rows})
    fin = max(r["date"] for r in rows)
    old = [e for e in ecritures(annees[0] + "-01-01") if e["date"][:4] in annees]
    # le grand livre fait foi jusqu'à sa dernière date : il remplace les écritures reprises, le CA,
    # et ce que Rodolph avait passé lui-même sur la même période (les saisies faites à la main sont gardées)
    a_suppr = [e["id"] for e in old if e["source"] in ("grand_livre", "ca")
               or (e["date"] <= fin and (e["source"] in ("facture", "banque", "carte")
                                         or (e.get("commentaire") or "").startswith(PROV_TAG)))]
    delete_ids(a_suppr)
    insert(rows)
    # les pièces déjà lues sont rattachées aux écritures du grand livre (même montant, date proche)
    pieces = af.sb_all("compta_pieces?select=id,fournisseur,total_ttc,date_piece,recu_le&statut=eq.traitee")
    neuves = ecritures(annees[0] + "-01-01")
    pris = {e["piece_id"] for e in neuves if e.get("piece_id")}
    n_lien = 0
    for p in pieces:
        if p["id"] in pris or p["total_ttc"] is None:
            continue
        d0 = dt.date.fromisoformat((p["date_piece"] or p["recu_le"] or "")[:10] or today().isoformat())
        c = [e for e in neuves if e["sens"] == "D" and not e.get("piece_id")
             and abs(float(e["ht"]) + float(e["tva"] or 0) - float(p["total_ttc"])) < 0.03
             and abs((dt.date.fromisoformat(e["date"]) - d0).days) <= 45]
        if c:
            e = min(c, key=lambda e: abs((dt.date.fromisoformat(e["date"]) - d0).days))
            af.sb(f"compta_ecritures?id=eq.{e['id']}", {"piece_id": p["id"]}, "PATCH")
            e["piece_id"] = p["id"]
            n_lien += 1
    note(f"grand livre repris : {len(rows)} écritures ({', '.join(annees)}, jusqu'au {fin[8:10]}/{fin[5:7]}), "
         f"{len(plan)} comptes, {len(a_suppr)} anciennes écritures remplacées, {n_lien} pièces rattachées")


def reprise_bp(wbv, wbf, nom):
    bp = X.bp(wbv, wbf)
    up = []
    for k, o in bp.items():
        for r in X.RUBRIQUES:
            up.append({"mois": k, "ligne": "L_" + r.upper(), "montant": o[r]})
        up += [{"mois": k, "ligne": "L_REEL", "montant": 1 if o["reel"] else 0},
               {"mois": k, "ligne": "L_DAP", "montant": o.get("dap")}, {"mois": k, "ligne": "L_FIN", "montant": o.get("fin")}]
        ebe = o["ca"] - sum(o[r] for r in X.RUBRIQUES[1:])
        up += [{"mois": k, "ligne": "CA", "montant": o["ca"]}, {"mois": k, "ligne": "EBE", "montant": round(ebe, 2)},
               {"mois": k, "ligne": "DAP", "montant": o.get("dap")},
               {"mois": k, "ligne": "RESULTAT", "montant": round(ebe - (o.get("dap") or 0) - (o.get("fin") or 0), 2)}]
    for i in range(0, len(up), 500):
        af.sb("compta_bp?on_conflict=mois,ligne", up[i:i + 500], "POST", "resolution=merge-duplicates,return=minimal")
    mois = sorted(bp)
    note(f"business plan repris : {len(mois)} mois ({mois[0]} → {mois[-1]}), réel jusqu'à "
         f"{max((k for k in mois if bp[k]['reel']), default='—')}")


# ───────────── 3. Banque (relevés CIC déposés dans Comptabilité) ─────────────
# Mêmes règles que l'écran Banque du dashboard : (motif, compte, fournisseur, taux de TVA, libellé)
REGLES = [
    (r"SALAIRE\s+([A-Z]+)", "641100", lambda m: m.group(1).capitalize(), 0, "Salaire net"),
    (r"URSSAF", "645100", "URSSAF", 0, "Cotisations URSSAF"), (r"ALPRO", "645500", "ALPRO", 0, "Prévoyance / retraite"),
    (r"ALAN", "645200", "ALAN ASSURANCE", 0, "Mutuelle"), (r"MULTI ENTREPRISE", "616200", "ACM", 0, "Assurance local"),
    (r"PRIMEO", "606110", "PRIMEO ENERGIE", .2, "Électricité"), (r"EXPRESSO", "613510", "EXPRESSO SERVICE", .2, "Location machine à café"),
    (r"KEYYO", "626300", "KEYYO", .2, "Internet"), (r"BOUYGUES", "626200", "BOUYGUES", .2, "Téléphone"),
    (r"SOFR|TELESURVEILLANCE", "613540", "SOFRATEL", .2, "Télésurveillance"), (r"QWEEKLE", "627100", "QWEEKLE", .2, "Commissions Qweekle"),
    (r"^FACT SGT|INTERETS/FRAIS|COMMISSION", "627800", "FRAIS BANCAIRES", .2, "Frais de banque"),
    (r"NPN", "607100", "NPN DISTRIBUTION", .055, "Snacking"), (r"METRO", "607100", "METRO", .055, "Snacking"),
    (r"CHALEUR TOURNANTE", "607100", "Chaleur tournante", .1, "Snacking"), (r"CAFES? RICHARD", "607100", "CAFES RICHARD", .055, "Snacking"),
    (r"MTAM", "615210", "MTAM", .2, "Ménage"), (r"PANSARD", "622600", "Pansard", .2, "Comptabilité"),
    (r"FEEDIZ", "623120", "FEEDIZ", .2, "ADS"), (r"ALISON", "623120", "ALISON ROUZIER", .2, "CM"),
    (r"PALO FRANCHISE", "651000", "PALO FRANCHISE", .2, "Redevances franchise"), (r"ANIMAT|STAFFEUR|RANGEUR", "621600", "ANIMATEURS", 0, "Animation"),
    (r"FACEBK|META", "623110", "META", 0, "META ADS"), (r"GOOGLE", "623110", "GOOGLE", 0, "Google Ads"),
    (r"ANTHROPIC|SPOTIFY|OVH|DIGITALEO|NETLIFY|GITHUB", "615660", lambda m: m.group(0).upper(), .2, "Abonnement logiciel"),
    (r"AMAZON|ACTION|LIDL|MATCH|CARREFOUR|CRF |LECLERC|BRICO|BM VILL|NATURE DECOU|LILMA|NORMAL", "606410", lambda m: m.group(0).upper().strip(), .2, "Fournitures parc"),
    (r"SANEF", "625002", "SANEF", .2, "Autoroute"), (r"TOTAL", "606140", "TOTALENERGIES", .2, "Carburant"),
    (r"FLUNC|ALFREDO|AUTOGRILL|TABLE D|RESTAU|MC ?DO", "625010", lambda m: m.group(0).upper(), .1, "Repas"),
    (r"FRAPA|AVOCAT", "622610", "FRAPA", .2, "Honoraires avocat"), (r"VISTAPRINT|SIGNELA|PRINT", "623000", lambda m: m.group(0).upper(), .2, "Impressions"),
    (r"NHOOD|LOYER", "613100", "NHOOD", .2, "Loyer"),
]
BQ_IN = re.compile(r"QWEEKLE.*SWEEP|TRANSFERT YAVIN|^VIR SGC|COMMUNITY|UNION FRANCAISE|DRFIP.*ANCV|^VRST|^REM CHQ|CENTRE SOCIAL|PROXI|COMMUNE|MAIRIE", re.I)
BQ_OUT = re.compile(r"DIRECTION GENERALE.*TVA|DGFIP.*TVA|^RELEVE CARTE|REMBOURSEMENT EMPRUNT|ECHEANCE PRET", re.I)
MOIS_PRECEDENT = {"641100", "645100", "645500"}   # salaires et cotisations : passés au mois de la période travaillée


def regle(lib):
    for motif, compte, four, t, l in REGLES:
        m = re.search(motif, lib, re.I)
        if m:
            return {"compte": compte, "fournisseur": four(m) if callable(four) else four, "taux": t, "libelle": l}
    return None


CLASSE = {"type": "object", "additionalProperties": False, "required": ["lignes"], "properties": {"lignes": {"type": "array", "items": {
    "type": "object", "additionalProperties": False, "required": ["cle", "hors_resultat", "compte", "fournisseur", "libelle", "taux", "raison"],
    "properties": {"cle": {"type": "string"}, "hors_resultat": {"type": "boolean"}, "compte": {"type": "string"},
                   "fournisseur": {"type": "string"}, "libelle": {"type": "string"}, "taux": {"type": "number"}, "raison": {"type": "string"}}}}}}


def classer(lignes, plan, histo):
    """Lignes bancaires sans règle ni pièce : Claude propose le compte (toujours « à vérifier »)."""
    if not lignes or not os.environ.get("ANTHROPIC_API_KEY"):
        return {}
    import anthropic
    client = anthropic.Anthropic()
    system = ("Tu es Rodolph, comptable de PALOMANO LILLE (parc de loisirs intérieur pour enfants). Pour chaque sortie d'argent du "
              "relevé CIC, propose le compte de charge du plan de comptes, le fournisseur (nom court en majuscules) et le taux de TVA "
              "probable. hors_resultat = vrai pour un mouvement qui n'est pas une charge (virement entre comptes, TVA, prêt, "
              "remboursement d'associé, caution). Explique en quelques mots dans raison.\n\nPLAN DE COMPTES :\n"
              + "\n".join(f"{p['compte']} — {p['libelle']}" for p in plan) + "\n\nHISTORIQUE (fournisseur → compte) :\n" + histo)
    resp = client.messages.create(model=af.MODEL, max_tokens=8000, system=system,
                                  output_config={"effort": "low", "format": {"type": "json_schema", "schema": CLASSE}},
                                  messages=[{"role": "user", "content": "\n".join(f"{b['cle']} | {b['date']} | {b['libelle']} | {b['montant']} €" for b in lignes)}])
    txt = next((b.text for b in resp.content if b.type == "text"), "{}")
    return {x["cle"]: x for x in json.loads(txt).get("lignes", [])}


def banque():
    lignes = af.sb_all("compta_banque?select=cle,date,libelle,montant,ecriture_id,ignore,note&ecriture_id=is.null&ignore=eq.false&date=gte.2026-01-01")
    todo = [b for b in lignes if float(b["montant"]) < 0 and not BQ_OUT.search(b["libelle"])]
    if not todo:
        return
    ecr = ecritures("2025-12-01")
    used = {e["id"] for e in ecr} & {b["ecriture_id"] for b in af.sb_all("compta_banque?select=ecriture_id&ecriture_id=not.is.null")}
    plan = af.sb_all("compta_plan?select=compte,libelle")
    comptes = {p["compte"] for p in plan}
    n_match = n_regle = n_ia = 0
    inconnues = []
    for b in sorted(todo, key=lambda b: b["date"]):
        t, d = -float(b["montant"]), dt.date.fromisoformat(b["date"])
        U = b["libelle"].upper()
        best, bd = None, 1e9
        for e in ecr:
            if e["id"] in used or e["sens"] != "D" or (e.get("commentaire") or "").startswith(PROV_TAG):
                continue
            ecart = min(abs(float(e["ht"]) + float(e["tva"] or 0) - t), abs(float(e["ht"]) - t))
            dd = (d - dt.date.fromisoformat(e["date"])).days
            if ecart > .05 or dd < -20 or dd > 75:
                continue
            nom = any(len(w) >= 4 and w in U for w in re.split(r"[^A-ZÀ-Ü0-9]+", str(e["fournisseur"]).upper()))
            if ecart > .005 and not nom:
                continue        # au centime près, ou bien le nom du fournisseur figure sur la ligne
            sc = abs(dd) - (100 if nom else 0)
            if sc < bd:
                best, bd = e, sc
        if best:
            af.sb(f"compta_banque?cle=eq.{urllib.parse.quote(b['cle'], safe='')}", {"ecriture_id": best["id"]}, "PATCH")
            if best.get("statut") == "provisoire":      # le paiement confirme l'écriture estimée
                af.sb(f"compta_ecritures?id=eq.{best['id']}", {"statut": "ok"}, "PATCH")
            used.add(best["id"])
            n_match += 1
            continue
        r = regle(b["libelle"])
        if not r:
            inconnues.append(b)
            continue
        date = fin_mois(mois_moins(b["date"][:7], 1)) if r["compte"] in MOIS_PRECEDENT and d.day <= 25 else b["date"]
        # salaire ou cotisation déjà passé pour ce mois (bulletin, avis du cabinet) avec un autre montant : pas de doublon
        deja = [e for e in ecr if str(e["compte"]) == r["compte"] and e["date"][:7] == date[:7] and not (e.get("commentaire") or "").startswith(PROV_TAG)
                and (e["fournisseur"] or "").split(" ")[0].lower() == r["fournisseur"].split(" ")[0].lower()]
        if r["compte"] in MOIS_PRECEDENT and deja and deja[0]["id"] not in used:
            af.sb(f"compta_banque?cle=eq.{urllib.parse.quote(b['cle'], safe='')}", {"ecriture_id": deja[0]["id"],
                  "note": f"écart {t - float(deja[0]['ht']):+.2f} € avec l'écriture"}, "PATCH")
            used.add(deja[0]["id"])
            n_match += 1
            continue
        remplacer_provision(ecr, r["compte"], r["fournisseur"], date[:7])
        ht = round(t / (1 + r["taux"]), 2)
        row = {"date": date, "compte": r["compte"], "fournisseur": r["fournisseur"], "libelle": r["libelle"], "taux": r["taux"],
               "sens": "D", "ht": ht, "tva": round(t - ht, 2), "statut": "ok", "source": "banque", "banque_cle": b["cle"],
               "commentaire": f"Relevé CIC du {b['date'][8:10]}/{b['date'][5:7]} : {b['libelle'][:120]} (Rodolph)"}
        e = insert([row])[0]
        ecr.append(e)
        used.add(e["id"])
        af.sb(f"compta_banque?cle=eq.{urllib.parse.quote(b['cle'], safe='')}", {"ecriture_id": e["id"]}, "PATCH")
        n_regle += 1
    if inconnues:
        histo = {}
        for e in ecr:
            if e["sens"] == "D" and e["fournisseur"]:
                histo[e["fournisseur"]] = e["compte"]
        try:
            prop = classer(inconnues[:40], plan, "\n".join(f"{f} → {c}" for f, c in sorted(histo.items())))
        except Exception as ex:
            prop = {}
            note(f"classement des lignes bancaires impossible : {ex}")
        for b in inconnues[:40]:
            x = prop.get(b["cle"])
            if not x:
                continue
            if x["hors_resultat"]:
                af.sb(f"compta_banque?cle=eq.{urllib.parse.quote(b['cle'], safe='')}", {"note": "Rodolph : hors résultat ? " + x["raison"][:200]}, "PATCH")
                continue
            t = -float(b["montant"])
            tx = x["taux"] if x["taux"] in (0, .055, .1, .2) else 0
            ht = round(t / (1 + tx), 2)
            e = insert([{"date": b["date"], "compte": x["compte"] if x["compte"] in comptes else "606410", "fournisseur": x["fournisseur"][:120],
                         "libelle": x["libelle"][:120], "taux": tx, "sens": "D", "ht": ht, "tva": round(t - ht, 2), "statut": "a_verifier",
                         "source": "banque", "banque_cle": b["cle"],
                         "commentaire": f"Relevé CIC du {b['date'][8:10]}/{b['date'][5:7]} : {b['libelle'][:100]} — proposé par Rodolph : {x['raison'][:150]}"}])[0]
            af.sb(f"compta_banque?cle=eq.{urllib.parse.quote(b['cle'], safe='')}", {"ecriture_id": e["id"]}, "PATCH")
            n_ia += 1
    note(f"banque : {n_match} ligne(s) rapprochée(s), {n_regle} passée(s) d'après les règles, {n_ia} proposée(s) à vérifier"
         + (f", {len(inconnues) - n_ia} sans proposition" if len(inconnues) > n_ia else ""))


# ───────────── 4. Provisions des charges récurrentes ─────────────
def nom1(f):
    """Premier mot du fournisseur : « Camille » et « Camille Pille », « NHOOD » et « NHOOD Services » vont ensemble."""
    w = re.split(r"[\s\-]+", (f or "").strip().lower())
    return w[0] if w else ""


def remplacer_provision(ecr, compte, four, mois):
    p = [e for e in ecr if e.get("statut") == "provisoire" and (e.get("commentaire") or "").startswith(PROV_TAG)
         and str(e["compte"]) == compte and e["date"][:7] == mois and nom1(e["fournisseur"]) == nom1(four)]
    if p:
        delete_ids(e["id"] for e in p)
        for e in p:
            ecr.remove(e)


def provisions():
    cur = today().isoformat()[:7]
    cibles = [mois_moins(cur, 1), cur]
    ecr = ecritures(mois_moins(cur, 6) + "-01")
    reel = [e for e in ecr if not (e.get("commentaire") or "").startswith(PROV_TAG) and e["sens"] == "D" and str(e["compte"]).startswith("6")
            and not str(e["compte"]).startswith(("607", "6216", "6217", "66", "67", "68", "69"))]
    prov = [e for e in ecr if (e.get("commentaire") or "").startswith(PROV_TAG)]
    cle = lambda e: (str(e["compte"]), nom1(e["fournisseur"]))
    n_new = n_upd = n_del = 0
    # une provision dont la vraie charge est arrivée disparaît
    reel_keys = {(cle(e), e["date"][:7]) for e in reel}
    obsoletes = [e["id"] for e in prov if (cle(e), e["date"][:7]) in reel_keys]
    delete_ids(obsoletes)
    n_del += len(obsoletes)
    prov = [e for e in prov if e["id"] not in obsoletes]
    for k in cibles:
        fen = [mois_moins(k, i) for i in range(1, 5)]
        montants = {}
        for e in reel:
            if e["date"][:7] in fen:
                montants.setdefault(cle(e), {}).setdefault(e["date"][:7], [0.0, e])
                montants[cle(e)][e["date"][:7]][0] += float(e["ht"])
        for key, par_mois in montants.items():
            if len(par_mois) < 3 or (key, k) in reel_keys:
                continue
            vals = [v[0] for v in par_mois.values()]
            med = statistics.median(vals)
            if med <= 0 or (statistics.pstdev(vals) / med > .35):
                continue      # montant trop irrégulier pour être provisionné
            mod = list(par_mois.values())[-1][1]
            t = mod.get("taux") or 0
            existe = [e for e in prov if cle(e) == key and e["date"][:7] == k]
            if existe:
                if abs(float(existe[0]["ht"]) - med) > .5:
                    af.sb(f"compta_ecritures?id=eq.{existe[0]['id']}", {"ht": round(med, 2), "tva": round(med * float(t), 2)}, "PATCH")
                    n_upd += 1
                continue
            insert([{"date": fin_mois(k), "compte": key[0], "fournisseur": mod["fournisseur"], "libelle": mod["libelle"] or "Charge récurrente",
                     "taux": t, "sens": "D", "ht": round(med, 2), "tva": round(med * float(t), 2), "statut": "provisoire", "source": "manuel",
                     "commentaire": f"{PROV_TAG} : charge récurrente (médiane des 4 mois précédents), remplacée dès l'arrivée de la pièce"}])
            n_new += 1
    note(f"provisions : {n_new} créée(s), {n_upd} ajustée(s), {n_del} remplacée(s) par la vraie charge")


# ───────────── 5. CA des mois terminés (saisie du jour) ─────────────
CA_MAP = [(1, "706300", "Entrées parc / Billetterie", .1), (2, "706400", "Anniversaires", .2), (3, "706500", "Groupes scolaires", .1),
          (4, "706500", "Centres de loisirs / Groupes", .1), (5, "707100", "Snacking", None), (6, "707200", "Vente boutique", .2),
          (7, "706300", "Évènements", .1)]


def ca_mensuel():
    p = HERE / "data.json"
    if not p.exists():
        return note("CA : data.json absent (lancer après build_dashboard.py)")
    data = json.loads(p.read_text(encoding="utf-8"))
    prov = set(data.get("aValider") or [])
    ecr = ecritures("2026-01-01")
    cur = today().isoformat()[:7]
    faits = []
    for k in sorted({r[0][:7] for r in data["daily"] if r[0] >= "2026-01-01"}):
        if k >= cur:
            break
        if any(e["date"][:7] == k and str(e["compte"]).startswith("7") and e.get("statut") != "provisoire" for e in ecr):
            continue
        rows = [r for r in data["daily"] if r[0].startswith(k)]
        if any(r[0] in prov for r in rows):
            continue        # journées encore à valider : le CA attend
        lignes = {}
        for i, c, l, t in CA_MAP:
            v = round(sum(float(r[i] or 0) for r in rows), 2)
            if v > 0:
                key = (c, l, t)
                lignes[key] = lignes.get(key, 0) + v
        if not lignes:
            continue
        delete_ids(e["id"] for e in ecr if e["date"][:7] == k and str(e["compte"]).startswith("7"))
        jours = sum(1 for r in rows if r[8] > 0)
        insert([{"date": fin_mois(k), "compte": c, "fournisseur": "QWEEKLE", "libelle": l, "taux": t, "sens": "C", "ht": v,
                 "tva": round(v * (t if t is not None else .089), 2), "statut": "ok", "source": "ca",
                 "commentaire": f"CA {k[5:7]}/{k[:4]} - saisie du jour validée ({jours} jours) (Rodolph)" + (" - TVA mixte estimée" if t is None else "")}
                for (c, l, t), v in lignes.items()])
        faits.append(k)
    note("CA enregistré pour " + ", ".join(faits) if faits else "CA : rien à enregistrer")


# ───────────── Passage ─────────────
def main():
    if not SB_URL or not SB_KEY:
        print("Rodolph : secrets Supabase absents, ignoré")
        return
    try:
        af.sb("compta_ecritures?select=id&limit=1", prefer="")
    except urllib.error.HTTPError:
        print("Rodolph : comptabilité pas encore installée (schema_v37), ignoré")
        return
    seul_ca = "--ca" in sys.argv
    erreurs = []
    etapes = [("CA", ca_mensuel)] if seul_ca else [("dépôts", depots), ("e-mails", None), ("banque", banque), ("provisions", provisions)]
    for nom, f in etapes:
        try:
            if f is None:
                r = af.main()
                if r:
                    note(f"e-mails : {r['mails']} examiné(s), {r['pieces']} pièce(s) lue(s), {r['ecritures']} écriture(s) créée(s)"
                         + (f" dont {r['a_verifier']} à vérifier" if r["a_verifier"] else "") + f", {r['liens']} rattachée(s)"
                         + (" · ⚠ " + " · ".join(r["alertes"][:4]) if r["alertes"] else ""))
            else:
                f()
        except Exception as e:      # une étape en échec n'empêche pas les autres
            erreurs.append(f"{nom} : {e}")
            print(f"Rodolph : étape {nom} en échec —", e)
    if seul_ca:
        try:
            old = af.sb("sync_state?select=message&key=eq.rodolph", prefer="")
            prev = (old[0]["message"] if old else "").split(" ‖ ")[0]
        except Exception:
            prev = ""
        etat(not erreurs, (prev + " ‖ " if prev else "") + " · ".join(journal + erreurs))
    else:
        etat(not erreurs, " · ".join(journal + erreurs) or "Rien de nouveau")


if __name__ == "__main__":
    main()
