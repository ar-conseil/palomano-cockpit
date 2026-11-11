#!/usr/bin/env python3
"""
Ventes de caisse du jour par catégorie, sous-catégorie et produit → table Supabase ventes_jour (schema_v28.sql).

Source : back-office Qweekle, page « Statistiques (h.t.) » (compte dédié, comme sync_commandes.py) :
  GET /reporting/sales/{categories|subcategories|products}?venture_id=…&filters[start_at]=JJ/MM/AAAA&filters[end_at]=…
  → tableau « Catégories | Nbr | Visiteurs | Nbr Ventes | Montant » (montants HT). Les acomptes et les
  bons cadeaux y sont des catégories à part (montants négatifs) : on les garde, l'espace équipe les écarte.

Sert à : pré-remplir la saisie du jour, répartir snacking / boutique dans « En direct », et compléter
« Mes chiffres » pour les jours pas encore saisis. On relit aujourd'hui et les 2 jours précédents à chaque
passage ; au premier passage, les 20 derniers jours.

Variables : QWEEKLE_EMAIL, QWEEKLE_PASSWORD, SUPABASE_URL, SUPABASE_SERVICE_KEY.
"""
import datetime as dt
import html
import re
import urllib.parse
from zoneinfo import ZoneInfo

from sync_commandes import Qweekle, SB_KEY, SB_URL, USER, sb

LEVELS = (("cat", "categories"), ("sub", "subcategories"), ("prod", "products"))
DAYS, BACKFILL = 3, 20


def state(ok, msg):
    sb("sync_state?on_conflict=key", [{"key": "qweekle_ventes", "ok": ok, "message": msg,
                                        "synced_at": dt.datetime.now(dt.timezone.utc).isoformat()}],
       "POST", "resolution=merge-duplicates,return=minimal")
    print("Ventes Qweekle : " + msg)


def cell(s):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s))).strip()


def number(s):
    s = re.sub(r"[^\d,.\-]", "", s or "")
    if not s or s in "-.,":
        return None
    if "," in s and "." in s:          # 3,853.47
        s = s.replace(",", "")
    elif "," in s:                      # 3853,47
        s = s.replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return None


def table(page):
    """Lignes du premier tableau : [{label, nbr, visiteurs, ventes, ht}] d'après les titres de colonnes."""
    m = re.search(r"<table\b.*?</table>", page, re.S | re.I)
    if not m:
        return None
    t = m.group(0)
    head = [cell(h).lower() for h in re.findall(r"<th\b[^>]*>(.*?)</th>", t, re.S | re.I)]
    def col(*names):
        for i, h in enumerate(head):
            if any(h == n or h.startswith(n) for n in names):
                return i
    c_nbr, c_vis, c_ven, c_ht = col("nbr", "quantité", "qté"), col("visiteurs"), col("nbr ventes", "nb ventes"), col("montant", "total")
    if c_nbr is not None and c_ven == c_nbr:          # « Nbr » et « Nbr Ventes » : le premier est la quantité
        c_ven = next((i for i, h in enumerate(head) if h.startswith("nbr ventes")), None)
    body = re.search(r"<tbody\b.*?</tbody>", t, re.S | re.I)
    out = []
    for tr in re.findall(r"<tr\b.*?</tr>", body.group(0) if body else t, re.S | re.I):
        tds = [cell(x) for x in re.findall(r"<td\b[^>]*>(.*?)</td>", tr, re.S | re.I)]
        if len(tds) < 2 or not tds[0]:
            continue
        get = lambda i: number(tds[i]) if i is not None and i < len(tds) else None
        ht = get(c_ht) if c_ht is not None else number(tds[-1])
        out.append({"label": tds[0][:200], "nbr": get(c_nbr), "visiteurs": get(c_vis), "ventes": get(c_ven), "ht": ht})
    return out


def main():
    if not SB_URL or not SB_KEY or not USER:
        print("Ventes Qweekle : secrets absents, ignoré")
        return
    if sb("sync_state?key=eq.qweekle_pause&select=message", prefer=""):
        print("Ventes Qweekle : lecture en pause")
        return
    q = Qweekle()
    try:
        q.login()
        q.op.addheaders.append(("X-Requested-With", "XMLHttpRequest"))
        _, page = q.get("/reporting")
        tok = re.search(r'name="_token"[^>]*value="([^"]+)"', page)
        ven = re.search(r'name="ventures\[\]"[^>]*value="([^"]+)"', page) or re.search(r'value="(V[A-Za-z0-9]{10,})"', page)
        if not tok or not ven:
            return state(False, "page Statistiques illisible (jeton ou établissement introuvable)")
        tok, ven = html.unescape(tok.group(1)), html.unescape(ven.group(1))

        def read(day, level):
            d = f"{day:%d/%m/%Y}"
            qs = urllib.parse.urlencode([("venture_id", ven), ("filters[_token]", tok), ("filters[ventures][]", ven),
                                         ("filters[quick]", "day"), ("filters[start_at]", d), ("filters[end_at]", d),
                                         ("filters[compare_range]", ""), ("filters[c_start_at]", ""), ("filters[c_end_at]", "")])
            url, txt = q.get(f"/reporting/sales/{level}?{qs}")
            if url.rstrip("/").endswith("/login"):
                raise PermissionError("session Qweekle perdue")
            return table(txt)

        today = dt.datetime.now(ZoneInfo("Europe/Paris")).date()
        have = {r["date"] for r in sb("ventes_jour?niveau=eq.cat&select=date", prefer="") or []}
        n = BACKFILL if len(have) < 5 else DAYS
        sig = lambda rows: sorted((r["label"], r["ht"]) for r in rows or [])
        ref = read(today, "categories")
        if ref is None:
            return state(False, "tableau des ventes introuvable dans la page Statistiques (format Qweekle modifié ?)")
        now = dt.datetime.now(dt.timezone.utc).isoformat()
        done, same = 0, 0
        for i in range(n):
            day = today - dt.timedelta(days=i)
            cats = ref if i == 0 else read(day, "categories")
            if i and ref and sig(cats) == sig(ref):
                same += 1                      # même tableau qu'aujourd'hui : la date n'a pas été prise en compte
                continue
            rows = [dict(r, date=day.isoformat(), niveau="cat", synced_at=now) for r in cats or []]
            for niveau, level in LEVELS[1:]:
                rows += [dict(r, date=day.isoformat(), niveau=niveau, synced_at=now) for r in read(day, level) or []]
            seen, uniq = set(), []
            for r in rows:
                k = (r["niveau"], r["label"])
                if k not in seen:
                    seen.add(k)
                    uniq.append(r)
            sb(f"ventes_jour?date=eq.{day.isoformat()}", method="DELETE")
            for j in range(0, len(uniq), 500):
                sb("ventes_jour?on_conflict=date,niveau,label", uniq[j:j + 500], "POST", "resolution=merge-duplicates,return=minimal")
            sb("live_ping?on_conflict=key", [{"key": "ventes_jour", "at": now}], "POST", "resolution=merge-duplicates,return=minimal")
            done += 1
        ca = sum(r["ht"] or 0 for r in ref if not re.search(r"acompte|cadeau", r["label"], re.I))
        state(True, f"aujourd'hui {len(ref)} catégories · {ca:.2f} € HT hors acomptes et bons cadeaux · {done} jour(s) lus"
                    + (f" · {same} jour(s) passé(s) ignoré(s) (date non prise en compte par Qweekle)" if same else ""))
    except PermissionError as e:
        state(False, f"lecture Qweekle impossible : {e}")
    except Exception as e:
        state(False, f"lecture des ventes Qweekle en échec : {e}")


if __name__ == "__main__":
    main()
