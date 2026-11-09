#!/usr/bin/env python3
"""
Lit la commande Qweekle de chaque anniversaire (back-office palomano.qweekle.com, compte dédié)
et la recopie dans l'espace équipe :

  · anniversaires.commande          produits de la commande, quantité + nom, SANS montant
                                    (Animateur, sirops, bonbons, gâteau, goodies, chaussettes…) ;
                                    l'option « Animateur » coche option_animateur (jamais décochée)
  · anniversaires.paiement          payé / acompte versé / non payé, d'après les montants
  · anniversaires_paiement          total, encaissé (acompte), reste à payer, lignes avec montants :
                                    lisible par la direction et les responsables seulement (RLS)

L'export « Liste des réservations » (import_qweekle.py) n'a ni les options ni les montants : ils ne
sont que dans la fiche de la commande. On lit donc la liste des réservations « Anniversaire »
(de J-14 à J+400) puis la fiche de chacune. Lancé après import_qweekle.py (les anniversaires
existent déjà) ; rattachement par date + nom du client.

Variables : QWEEKLE_EMAIL, QWEEKLE_PASSWORD (secrets GitHub, compte Qweekle dédié),
            SUPABASE_URL, SUPABASE_SERVICE_KEY. QWEEKLE_URL (défaut https://palomano.qweekle.com).
"""
import datetime as dt
import html
import http.cookiejar
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

BASE = os.environ.get("QWEEKLE_URL", "https://palomano.qweekle.com").rstrip("/")
USER, PWD = os.environ.get("QWEEKLE_EMAIL", ""), os.environ.get("QWEEKLE_PASSWORD", "")
SB_URL, SB_KEY = os.environ.get("SUPABASE_URL", "").rstrip("/"), os.environ.get("SUPABASE_SERVICE_KEY", "")
PAST_DAYS, AHEAD_DAYS = 14, 400
FORMULE = re.compile(r"^(palo-?fiesta|anniversaire\b)", re.I)        # la formule elle-même, pas une option


# ───────────── Supabase ─────────────
def sb(path, body=None, method="GET", prefer="return=minimal"):
    req = urllib.request.Request(f"{SB_URL}/rest/v1/{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}",
                                          "Content-Type": "application/json", "Prefer": prefer})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def state(ok, msg):
    sb("sync_state?on_conflict=key", [{"key": "qweekle_commandes", "ok": ok, "message": msg,
                                        "synced_at": dt.datetime.now(dt.timezone.utc).isoformat()}],
       "POST", "resolution=merge-duplicates,return=minimal")
    print("Commandes Qweekle : " + msg)


# ───────────── Qweekle (session du back-office) ─────────────
class Qweekle:
    def __init__(self):
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.op.addheaders = [("User-Agent", "Mozilla/5.0 (PalomanoDashboard)"), ("Accept-Language", "fr-FR,fr")]

    def get(self, url, data=None):
        url = url if url.startswith("http") else BASE + url
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        with self.op.open(urllib.request.Request(url, data=body), timeout=45) as r:
            return r.geturl(), r.read().decode("utf-8", "replace")

    def login(self):
        _, page = self.get("/login")
        form = {n: html.unescape(v) for n, v in
                re.findall(r'<input[^>]*name="([^"]+)"[^>]*value="([^"]*)"', page)}
        form.update({"username": USER, "password": PWD, "login": ""})
        url, _ = self.get("/login", form)
        if url.rstrip("/").endswith("/login"):
            raise PermissionError("connexion refusée (identifiant ou mot de passe Qweekle du compte dédié ?)")

    def bookings(self, d0, d1):
        """URLs des fiches des réservations « Anniversaire » entre d0 et d1."""
        urls = []
        for page in range(1, 60):
            q = urllib.parse.urlencode({"filters[agendas__start_at]": "", "filters[agendas__from_at]": f"{d0:%d/%m/%Y}",
                                        "filters[agendas__to_at]": f"{d1:%d/%m/%Y}",
                                        "filters[activities__label]": "Anniversaire",
                                        "filters[agenda_bookings__expirated]": "0", "page": page})
            url, txt = self.get(f"/planning/v2/bookings?{q}")
            if url.rstrip("/").endswith("/login"):
                raise PermissionError("session Qweekle perdue")
            rows = [r for r in re.findall(r"<tr\b.*?</tr>", txt, re.S) if "data-booking_url" in r]
            if not rows:
                break
            for r in rows:
                if re.search(r"Entr[ée]e\s+Enfant\s+Anniversaire", text(r), re.I):
                    continue                      # 2e ligne de la même commande
                m = re.search(r'data-booking_url="([^"]+)"', r)
                if m:
                    urls.append(html.unescape(m.group(1)))
        return list(dict.fromkeys(urls))


def text(h):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", h or "")).replace("\xa0", " ")).strip()


def money(s):
    s = re.sub(r"[^\d,.\-]", "", (s or "").replace("\xa0", "").replace(" ", "")).replace(",", ".")
    try:
        return round(float(s), 2)
    except ValueError:
        return None


def parse_panel(h):
    """Fiche d'une réservation → client, date de la fête, n° de commande, produits, montants."""
    out = {"client": "", "start": None, "commande": "", "lignes": [], "total": None, "encaisse": None, "reste": None,
           "annule": False}
    m = re.search(r"<h4[^>]*>(.*?)</h4>", h, re.S)
    out["client"] = text(m.group(1)) if m else ""
    rib = re.search(r'booking_state_ribbon[^"]*"[^>]*>(.*?)</div>', h, re.S)
    out["annule"] = bool(rib and re.search(r"annul", text(rib.group(1)), re.I))
    m = re.search(r"Commande N°\s*([A-Z]-[\d-]+)", text(h))
    out["commande"] = m.group(1) if m else ""
    last = None
    for tb in re.findall(r"<table\b.*?</table>", h, re.S):
        for tr in re.findall(r"<tr\b.*?</tr>", tb, re.S):
            cells = [text(c) for c in re.findall(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", tr, re.S)]
            if len(cells) >= 3 and re.fullmatch(r"\d+", cells[0]):
                last = {"q": int(cells[0]), "p": cells[1], "m": money(cells[2]), "formule": bool(FORMULE.match(cells[1]))}
                out["lignes"].append(last)
                continue
            joined = " ".join(cells)
            sub = re.search(r"(.+?) - (\d\d/\d\d/\d{4} \d\d:\d\d)", joined)
            if sub and len(cells) <= 2 and not re.match(r"\d\d/\d\d/\d{4} [A-Z]-", joined):
                if last:
                    last["formule"] = True        # produit qui porte les créneaux réservés = la formule
                when = dt.datetime.strptime(sub.group(2), "%d/%m/%Y %H:%M")
                if out["start"] is None or ("anniversaire" in sub.group(1).lower() and when < out["start"]):
                    out["start"] = when
                continue
            if len(cells) == 2:
                lab = cells[0].lower()
                if lab.startswith("total de la commande"):
                    out["total"] = money(cells[1])
                elif lab.startswith("paiements encaiss"):
                    out["encaisse"] = money(cells[1])
                elif lab == "solde" or lab.startswith("paiements attendus"):
                    out["reste"] = money(cells[1])
    if out["total"] is not None:
        out["encaisse"] = out["encaisse"] or 0.0
        if out["reste"] is None:
            out["reste"] = round(out["total"] - out["encaisse"], 2)
    return out


def tokens(*names):
    t = unicodedata.normalize("NFKD", " ".join(str(n or "") for n in names)).encode("ascii", "ignore").decode().lower()
    return frozenset(w for w in re.split(r"[^a-z]+", t) if len(w) > 1)


def paiement(o):
    if o["total"] is None:
        return None
    if o["total"] > 0 and (o["reste"] or 0) <= 0.009:
        return "paye"
    return "acompte" if (o["encaisse"] or 0) > 0 else "non_paye"


def main():
    if not SB_URL or not SB_KEY:
        print("Commandes Qweekle : secrets Supabase absents, ignoré")
        return
    if not USER or not PWD:
        state(False, "compte Qweekle dédié non configuré (secrets QWEEKLE_EMAIL et QWEEKLE_PASSWORD) : "
                     "options et montants des anniversaires non lus")
        return
    today = dt.date.today()
    d0, d1 = today - dt.timedelta(days=PAST_DAYS), today + dt.timedelta(days=AHEAD_DAYS)
    q = Qweekle()
    try:
        q.login()
        urls = q.bookings(d0, d1)
        orders, seen = [], set()
        for u in urls:
            o = parse_panel(q.get(u)[1])
            time.sleep(0.15)
            if not o["start"] or o["annule"] or (o["commande"] and o["commande"] in seen):
                continue
            seen.add(o["commande"])
            orders.append(o)
    except Exception as e:
        state(False, f"lecture Qweekle impossible : {e}")
        return
    if urls and not orders:
        state(False, f"{len(urls)} fiches lues mais aucune commande reconnue (format Qweekle modifié ?)")
        return

    db = sb(f"anniversaires?date=gte.{d0}&date=lte.{d1}&statut=neq.annule"
            "&select=id,date,heure,parent_nom,option_animateur,commande,paiement", prefer="")
    by_day = {}
    for a in db:
        by_day.setdefault(a["date"], []).append(a)
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    linked, anim, changed, pays = 0, 0, 0, []
    for o in orders:
        cands = by_day.get(o["start"].date().isoformat(), [])
        tk = tokens(o["client"])
        match = [a for a in cands if tokens(a["parent_nom"]) == tk] or \
                [a for a in cands if tk and (tokens(a["parent_nom"]) <= tk or tk <= tokens(a["parent_nom"]))]
        if not match:
            continue
        hhmm = o["start"].strftime("%H:%M")
        a = min(match, key=lambda x: abs(int(x["heure"][:2]) * 60 + int(x["heure"][3:5]) - int(hhmm[:2]) * 60 - int(hhmm[3:])))
        linked += 1
        opts = [{"q": l["q"], "p": l["p"]} for l in o["lignes"] if not l["formule"]]
        has_anim = any(re.search(r"animat", l["p"], re.I) for l in opts)
        anim += has_anim
        patch = {}
        if a.get("commande") != opts:
            patch["commande"] = opts
        if has_anim and not a.get("option_animateur"):
            patch["option_animateur"] = True          # jamais décochée : l'équipe peut aussi la cocher
        p = paiement(o)
        if p and a.get("paiement") != p:
            patch["paiement"] = p
        if patch:
            sb(f"anniversaires?id=eq.{a['id']}", {**patch, "commande_sync_at": now, "updated_at": now}, "PATCH")
            changed += 1
        pays.append({"anniversaire_id": a["id"], "commande": o["commande"], "total": o["total"],
                     "encaisse": o["encaisse"], "reste": o["reste"],
                     "lignes": [{"q": l["q"], "p": l["p"], "m": l["m"]} for l in o["lignes"]], "synced_at": now})
    if pays:
        sb("anniversaires_paiement?on_conflict=anniversaire_id", pays, "POST", "resolution=merge-duplicates,return=minimal")
    lost = len(orders) - linked
    state(True, f"{len(orders)} commandes anniversaire lues, {linked} rattachées"
                + (f" ({lost} sans anniversaire correspondant, export réservations à refaire ?)" if lost else "")
                + f", {anim} avec animateur, {changed} mises à jour")


if __name__ == "__main__":
    main()
