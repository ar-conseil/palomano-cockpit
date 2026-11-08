#!/usr/bin/env python3
"""
Importe les réservations Qweekle (anniversaires, centres de loisirs, écoles, groupes) dans
l'espace équipe (tables Supabase anniversaires et groupes).

Qweekle n'a pas d'API : on part de l'export Excel du back-office
(Réservations › Liste des réservations › Export, fichier « B-JJ-MM-AAAA-HH-MM_xxxx.xlsx »)
déposé tel quel dans SharePoint « PARC/SUIVI PARC ». Le plus récent est lu en mémoire,
jamais écrit sur disque.

Colonnes de l'export : Actif, Origine, Créneau réservé, Client, e-mail client, téléphone client,
Activité réservée, Nbre participants, Lieu, Statut, Réservé le, Note en ligne, Note interne.
Une réservation = plusieurs lignes (Enfant / Adulte, entrée + formule anniversaire).

- Clé stable : l'export n'a pas de n° de réservation ; on prend Client + « Réservé le »
  (horodatage de création, inchangé si le créneau est déplacé).
- Les champs de l'équipe (notes, salle, thème, animateur, référent, prénom de l'enfant)
  ne sont jamais écrasés ; aucun montant n'est importé.
- État de paiement (colonne Statut) : payé, acompte versé, non payé, option. L'export n'a pas de montant.
- Option « Animateur » : produit vendu sur place seulement (ni en ligne ni au planning), donc absent de
  l'export des réservations. Lue dans l'export caisse, rattachée par le nom du client et la date de vente ;
  l'import ne fait que cocher l'option (jamais la décocher), l'équipe peut la cocher à la main avant la fête.
- Une réservation importée qui disparaît d'un export plus récent couvrant sa date
  (annulée dans Qweekle) passe en « annulé ».

Variables : SUPABASE_URL, SUPABASE_SERVICE_KEY, plus celles de fetch_sharepoint.py.
"""
import datetime as dt
import hashlib
import html
import io
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import unicodedata
import zipfile
from pathlib import Path
from xml.etree.ElementTree import iterparse

import fetch_sharepoint as fs

FOLDER = os.environ.get("SP_FOLDER", "PARC/SUIVI PARC")
NAME_RE = re.compile(r"^(B-\d{2}-\d{2}-\d{4}.*|qweekle.*)\.xlsx$", re.I)
NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
STALE_DAYS = 3          # au-delà, l'app signale qu'il faut redéposer un export
SB_URL, SB_KEY = os.environ.get("SUPABASE_URL", "").rstrip("/"), os.environ.get("SUPABASE_SERVICE_KEY", "")

# Champs dont Qweekle est la source (mis à jour à chaque import). Tout le reste appartient à l'équipe.
OWN_ANNIV = ["date", "heure", "nb_enfants", "formule", "parent_nom", "parent_tel", "parent_email",
             "statut", "paiement", "qweekle_note"]
OWN_GROUPE = ["type", "structure", "date", "heure_arrivee", "nb_enfants", "nb_encadrants", "contact_nom",
              "contact_tel", "contact_email", "statut", "paiement", "qweekle_note"]


def sb(path, body=None, method="GET", prefer="return=minimal"):
    req = urllib.request.Request(f"{SB_URL}/rest/v1/{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}",
                                          "Content-Type": "application/json", "Prefer": prefer})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


# ───────────── Lecture de l'Excel en flux (comme read_ventes.py, avec les chaînes partagées) ─────────────
def _col(ref):
    n = 0
    for ch in re.match(r"[A-Z]+", ref).group():
        n = n * 26 + ord(ch) - 64
    return n - 1


def iter_rows(data):
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        strings = []
        if "xl/sharedStrings.xml" in z.namelist():
            with z.open("xl/sharedStrings.xml") as f:
                for _, el in iterparse(f):
                    if el.tag == NS + "si":
                        strings.append("".join(t.text or "" for t in el.iter(NS + "t")))
                        el.clear()
        sheet = sorted(n for n in z.namelist() if re.match(r"xl/worksheets/sheet\d+\.xml$", n))[0]
        with z.open(sheet) as f:
            row = {}
            for _, el in iterparse(f):
                if el.tag == NS + "c":
                    t, v = el.get("t"), el.find(NS + "v")
                    if t == "inlineStr":
                        val = "".join(x.text or "" for x in el.iter(NS + "t"))
                    elif v is None:
                        val = None
                    elif t == "s":
                        val = strings[int(v.text)]
                    else:
                        val = v.text
                    if val not in (None, ""):
                        row[_col(el.get("r"))] = val.strip() if isinstance(val, str) else val
                    el.clear()
                elif el.tag == NS + "row":
                    yield [row.get(i) for i in range(max(row) + 1)] if row else []
                    row = {}
                    el.clear()


def to_dt(v):
    """« 2027-01-26 09:30:00 » (texte) ou numéro de série Excel."""
    if v is None:
        return None
    try:
        return dt.datetime.fromisoformat(str(v))
    except ValueError:
        pass
    try:
        return dt.datetime(1899, 12, 30) + dt.timedelta(days=float(v))
    except ValueError:
        return None


def kind_of(activite):
    a = activite.lower()
    if "anniversaire" in a:
        return "anniv"
    if a.startswith("scolaire"):
        return "ecole"
    if a.startswith("accueil de loisirs") or a.startswith("groupe"):
        return "centre"
    return None   # entrées individuelles : pas une réservation à préparer


def statut(state, origin, groupe):
    if state == "proposal":
        return "devis" if groupe and origin == "quote_order" else "option"
    return "confirme"   # accepted, partially_paid, sold


PAIEMENT = {"sold": "paye", "partially_paid": "acompte", "accepted": "non_paye", "proposal": "option"}


def clean_note(v):
    """Les notes en ligne Qweekle arrivent parfois en HTML (« <p>…</p> ») : texte simple."""
    t = re.sub(r"<br\s*/?>|</p>\s*<p[^>]*>", "\n", str(v or ""), flags=re.I)
    return re.sub(r"[ \t]+", " ", html.unescape(re.sub(r"<[^>]+>", "", t))).strip()


def phone(v):
    s = str(v or "").split(".")[0].strip()
    return "0" + s if s.isdigit() and len(s) == 9 else s


def parse(data):
    rows = iter_rows(data)
    head = next(rows)
    ix = {h: i for i, h in enumerate(head) if h}
    need = ["Créneau réservé", "Client", "Activité réservée", "Nbre participants", "Statut", "Réservé le"]
    missing = [h for h in need if h not in ix]
    if missing:
        raise ValueError(f"colonnes absentes de l'export : {', '.join(missing)} (format Qweekle modifié ?)")
    g = lambda r, k: r[ix[k]] if k in ix and ix[k] < len(r) else None

    resas, dates = {}, []
    for r in rows:
        if not r or str(g(r, "Actif") or "1") in ("0", "0.0"):
            continue
        act, start = g(r, "Activité réservée") or "", to_dt(g(r, "Créneau réservé"))
        if start:
            dates.append(start.date())
        kind = kind_of(act)
        client = g(r, "Client") or ""
        if not kind or not start or not client:
            continue
        key = "qw-" + hashlib.sha1(f"{client}|{g(r, 'Réservé le')}".encode()).hexdigest()[:16]
        res = resas.setdefault(key, {"kind": kind, "start": start, "client": client, "kids": 0, "adults": 0,
                                     "booked": to_dt(g(r, "Réservé le")),
                                     "formule": "", "email": g(r, "e-mail client") or "",
                                     "tel": phone(g(r, "téléphone client")), "note": clean_note(g(r, "Note en ligne")),
                                     "state": g(r, "Statut"), "origin": g(r, "Origine"), "label": act})
        n = int(float(g(r, "Nbre participants") or 0))
        res["start"] = min(res["start"], start)
        low = act.lower()
        if kind == "anniv":
            if low.startswith("anniversaire"):
                res["formule"] = act.split("Anniversaire", 1)[1].strip().capitalize()
                res["kids"] = max(res["kids"], n)
            elif "enfant" in low:
                res["kids"] = max(res["kids"], n)
        elif "adulte" in low:
            res["adults"] += n
        else:
            res["kids"] += n
            if low.startswith("groupe"):
                res["groupe"] = True
    return resas, (min(dates), max(dates)) if dates else (None, None)


# ───────────── Option « Animateur » : produit de la commande, visible seulement dans l'export caisse ─────────────
def tokens(*names):
    t = unicodedata.normalize("NFKD", " ".join(str(n or "") for n in names)).encode("ascii", "ignore").decode().lower()
    return frozenset(w for w in re.split(r"[^a-z]+", t) if len(w) > 1)


OPTIONS = [(re.compile(r"animateur\b", re.I), "Animateur"),
           (re.compile(r"g[aâ]teau au chocolat", re.I), "Gâteau au chocolat"),
           (re.compile(r"g[aâ]teau aux pommes", re.I), "Gâteau aux pommes"),
           (re.compile(r"pochette goodies", re.I), "Pochette goodies"),
           (re.compile(r"soft oasis", re.I), "Soft Oasis"),
           (re.compile(r"bonbons non v", re.I), "Bonbons non végétariens"),
           (re.compile(r"bonbons v", re.I), "Bonbons végétariens")]


def option_sales():
    """{noms du client : [(date de vente, option)]} des options anniversaire de l'export caisse le plus récent (ou None)."""
    src = Path(os.environ.get("PALOMANO_SUIVI_DIR", "sources"))
    files = sorted(src.glob("palomano-la-maillerie__*.xlsx"), key=lambda f: f.stat().st_mtime)
    if not files:
        return None, None
    from read_ventes import iter_rows as caisse_rows
    rows = caisse_rows(files[-1])
    ix = {h: i for i, h in enumerate(next(rows))}
    g = lambda r, k: r[ix[k]] if k in ix and ix[k] < len(r) else None
    out = {}
    for r in rows:
        if not r or g(r, "Vente supprimée le") or "annul" in str(g(r, "Statut") or "").lower():
            continue
        name = re.sub(r"^\s*\[[^\]]*\]\s*", "", str(g(r, "Produit") or g(r, "Produit & Paiement") or ""))
        label = next((lab for rx, lab in OPTIONS if rx.search(name)), None)
        ts = g(r, "Enregistré le")
        if label and isinstance(ts, str) and len(ts) >= 10:
            out.setdefault(tokens(g(r, "Prénom Client"), g(r, "Nom Client")), []).append((dt.date.fromisoformat(ts[:10]), label))
    return out, files[-1].name


def options_of(r, sales):
    """Options achetées par le même client entre la réservation et le jour de la fête."""
    lo = (r["booked"] or r["start"]).date() - dt.timedelta(days=1)
    hi = r["start"].date() + dt.timedelta(days=1)
    return {lab for d, lab in sales.get(tokens(r["client"])) or [] if lo <= d <= hi}


def has_animateur(r, sales):
    return "Animateur" in options_of(r, sales)


def record(key, r):
    st = statut(r["state"], r["origin"], r["kind"] != "anniv")
    if st == "confirme" and r["start"].date() < dt.date.today():
        st = "termine"                          # réservation passée (historique des derniers mois)
    common = {"qweekle_id": key, "date": r["start"].date().isoformat(), "qweekle_note": r["note"],
              "statut": st,
              "paiement": PAIEMENT.get(r["state"])}
    if r["kind"] == "anniv":
        return "anniversaires", {**common, "heure": r["start"].strftime("%H:%M"), "nb_enfants": r["kids"] or None,
                                 "formule": r["formule"], "parent_nom": r["client"], "parent_tel": r["tel"],
                                 "parent_email": r["email"]}
    return "groupes", {**common, "type": r["kind"], "structure": r["client"], "heure_arrivee": r["start"].strftime("%H:%M"),
                       "nb_enfants": r["kids"] or None, "nb_encadrants": r["adults"] or None,
                       "contact_nom": r["client"], "contact_tel": r["tel"], "contact_email": r["email"]}


def same(a, b):
    if isinstance(a, str) and isinstance(b, str) and re.fullmatch(r"\d\d:\d\d(:\d\d)?", a or ""):
        return a[:5] == b[:5]
    return a == b


def latest_export(tok):
    url = (f"https://graph.microsoft.com/v1.0/drives/{fs.DRIVE_ID}/root:/{urllib.parse.quote(FOLDER)}:/children"
           "?$select=id,name,lastModifiedDateTime&$top=200")
    with fs.graph(url, tok) as r:
        items = [i for i in json.load(r)["value"] if NAME_RE.match(i["name"])]
    if not items:
        return None, None
    item = max(items, key=lambda i: i["lastModifiedDateTime"])
    with fs.graph(f"https://graph.microsoft.com/v1.0/drives/{fs.DRIVE_ID}/items/{item['id']}/content", tok) as r:
        return item, r.read()


def state(ok, msg):
    sb("sync_state?on_conflict=key", [{"key": "qweekle", "ok": ok, "message": msg,
                                        "synced_at": dt.datetime.now(dt.timezone.utc).isoformat()}],
       "POST", "resolution=merge-duplicates,return=minimal")
    print("Qweekle : " + msg)


def main():
    if not SB_URL or not SB_KEY:
        print("Qweekle : secrets Supabase absents, import ignoré")
        return
    item, data = latest_export(fs.access_token())
    if not item:
        state(False, f"aucun export Qweekle (« B-….xlsx ») dans {FOLDER}")
        return
    try:
        resas, (d0, d1) = parse(data)
    except Exception as e:
        state(False, f"export « {item['name']} » illisible : {e}")
        sys.exit(1)

    try:
        sales, caisse = option_sales()
    except Exception as e:                      # l'option animateur ne doit jamais bloquer l'import
        print(f"::warning::Option animateur non lue dans l'export caisse : {e}")
        sales, caisse = None, None
    own_anniv = OWN_ANNIV + (["option_animateur"] if sales is not None else [])
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    created = updated = cancelled = 0
    for table, own in (("anniversaires", own_anniv), ("groupes", OWN_GROUPE)):
        cols = ",".join(own + (["options"] if table == "anniversaires" else []))
        db = {r["qweekle_id"]: r for r in sb(f"{table}?qweekle_id=not.is.null&select=id,qweekle_id,{cols}", prefer="")}
        seen = set()
        for key, r in resas.items():
            t, rec = record(key, r)
            if t != table:
                continue
            found = options_of(r, sales) if t == "anniversaires" and sales is not None else set()
            if "Animateur" in found:
                rec["option_animateur"] = True   # jamais remis à « non » : l'équipe peut cocher l'option à la main
            found.discard("Animateur")
            seen.add(key)
            cur = db.get(key)
            if found:                            # options vendues en caisse : ajoutées, jamais retirées
                have = set((cur or {}).get("options") or [])
                if not found <= have:
                    rec["options"] = sorted(have | found)
            if not cur:
                if table == "anniversaires":
                    rec["enfant"] = f"Enfant de {r['client']}"   # prénom à compléter par l'équipe
                elif r.get("groupe"):
                    rec["niveau"] = "Groupe"
                rec["qweekle_sync_at"] = now
                sb(table, rec, "POST")
                created += 1
                continue
            patch = {k: rec[k] for k in own + ["options"] if k in rec and not same(cur.get(k), rec.get(k))}
            if cur.get("statut") == "termine":
                patch.pop("statut", None)
            if patch:
                sb(f"{table}?id=eq.{cur['id']}", {**patch, "qweekle_sync_at": now, "updated_at": now}, "PATCH")
                updated += 1
        # Disparue d'un export qui couvre sa date : annulée dans Qweekle
        if d0 and d1:
            gone = [c for k, c in db.items() if k not in seen and d0.isoformat() <= c["date"] <= d1.isoformat()
                    and c["statut"] not in ("annule", "termine")]
            if len(gone) > max(5, len(seen) // 3):
                print(f"::warning::{len(gone)} {table} absentes de l'export : export partiel ? annulation non appliquée")
            else:
                for c in gone:
                    sb(f"{table}?id=eq.{c['id']}", {"statut": "annule", "qweekle_sync_at": now, "updated_at": now}, "PATCH")
                    cancelled += 1

    age = (dt.datetime.now(dt.timezone.utc)
           - dt.datetime.fromisoformat(item["lastModifiedDateTime"].replace("Z", "+00:00"))).days
    n = {k: sum(1 for r in resas.values() if r["kind"] == k) for k in ("anniv", "centre", "ecole")}
    if sales is not None:
        n_anim = sum(1 for r in resas.values() if r["kind"] == "anniv" and has_animateur(r, sales))
        print(f"Qweekle : option animateur sur {n_anim} anniversaire(s) sur {n['anniv']} (caisse « {caisse} »)")
    msg = (f"{n['anniv']} anniversaires, {n['centre']} centres/groupes, {n['ecole']} écoles"
           + (f" du {d0:%d/%m/%Y} au {d1:%d/%m/%Y}" if d0 else "")
           + f" · {created} ajoutées, {updated} mises à jour, {cancelled} annulées · « {item['name']} »")
    if age > STALE_DAYS:
        msg = f"export Qweekle vieux de {age} jours, à refaire · " + msg
    state(age <= STALE_DAYS, msg)


if __name__ == "__main__":
    main()
