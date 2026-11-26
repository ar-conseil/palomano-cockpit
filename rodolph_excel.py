#!/usr/bin/env python3
"""
Rodolph — lecture des fichiers Excel de la direction (aucune écriture ici, seulement de la lecture).

  grand_livre(wb)  onglet « GRAND LIVRE » du fichier « 2026 LPP PALOMANO LILLE » → écritures (même logique que le LPP)
  plan(wb)         onglet « BDD » du même fichier → plan de comptes et regroupements
  bp(wbv, wbf)     onglets « Projection AAAA » du fichier « PALOMANO LILLE 2025 2026 - avec TVA - AVENANT … »
                   → par mois : CA, achats, franchise, intérim, structure, masse salariale, DAP, frais financiers,
                   et si le mois est du réel ou de la projection.

Les fichiers enregistrés par un script (et pas par Excel) n'ont pas les résultats de leurs formules : les formules
simples (opérations, références, SUM) sont donc recalculées ici.
"""
import datetime as dt
import re

# ───────────── Petite évaluation de formules Excel ─────────────
REF = re.compile(r"(?:'([^']+)'|([A-Za-zÀ-ÿ0-9_]+))?!?\$?([A-Z]{1,3})\$?(\d+)")
CELL = re.compile(r"(?:(?:'([^']+)'|([A-Za-zÀ-ÿ0-9_]+))!)?\$?([A-Z]{1,3})\$?(\d+)")
RANGE = re.compile(r"SUM\(\s*(?:(?:'([^']+)'|([A-Za-zÀ-ÿ0-9_]+))!)?\$?([A-Z]{1,3})\$?(\d+)\s*:\s*\$?([A-Z]{1,3})\$?(\d+)\s*\)", re.I)
SAFE = re.compile(r"^[0-9.eE+\-*/() ]*$")


def col_num(c):
    n = 0
    for ch in c:
        n = n * 26 + ord(ch) - 64
    return n


def col_txt(n):
    s = ""
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


class Evaluateur:
    """Valeur d'une cellule : la valeur enregistrée si elle existe, sinon la formule recalculée."""

    def __init__(self, wbv, wbf):
        self.wbv, self.wbf, self.memo = wbv, wbf, {}

    def val(self, sheet, col, row):
        k = (sheet, col, row)
        if k in self.memo:
            return self.memo[k]
        self.memo[k] = None                       # protège des références circulaires
        v = self.wbv[sheet].cell(row, col).value if sheet in self.wbv.sheetnames else None
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            out = float(v)
        else:
            f = self.wbf[sheet].cell(row, col).value if sheet in self.wbf.sheetnames else None
            out = (self.formule(sheet, f) if isinstance(f, str) and f.startswith("=")
                   else 0.0 if v is None or (isinstance(v, str) and not v.strip()) else num(v))
        self.memo[k] = out
        return out

    def formule(self, sheet, f):
        expr = f[1:]

        def si(m):   # IF(cellule="TEXTE", a, b) : seul cas de condition utilisé dans le BP
            txt = str(self.wbv[sheet].cell(int(m.group(2)), col_num(m.group(1))).value or "").strip().upper()
            return "(" + (m.group(4) if txt == m.group(3).upper() else m.group(5)) + ")"

        expr = re.sub(r'IF\(\s*\$?([A-Z]{1,3})\$?(\d+)\s*=\s*"([^"]*)"\s*,([^,()]+),([^,()]+)\)', si, expr, flags=re.I)

        def somme(m):
            sh = m.group(1) or m.group(2) or sheet
            c1, r1, c2, r2 = col_num(m.group(3)), int(m.group(4)), col_num(m.group(5)), int(m.group(6))
            tot = 0.0
            for r in range(min(r1, r2), max(r1, r2) + 1):
                for c in range(min(c1, c2), max(c1, c2) + 1):
                    tot += self.val(sh, c, r) or 0.0
            return f"({tot!r})"

        expr = RANGE.sub(somme, expr)

        def ref(m):
            sh = m.group(1) or m.group(2) or sheet
            v = self.val(sh, col_num(m.group(3)), int(m.group(4)))
            return f"({(v or 0.0)!r})"

        expr = CELL.sub(ref, expr)
        if not SAFE.match(expr):
            return None                           # fonction non gérée (IF, VLOOKUP…) : valeur inconnue
        try:
            return float(eval(expr, {"__builtins__": {}}, {}))   # noqa: S307 — expression réduite à des chiffres et opérateurs
        except (SyntaxError, ZeroDivisionError, TypeError, ValueError):
            return None


def num(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(str(v).replace(",", ".").replace(" ", "").replace(" ", ""))
    except ValueError:
        return None


def taux(h):
    if isinstance(h, (int, float)):
        return float(h)
    m = re.search(r"([\d.,]+)\s*%", str(h or ""))
    if m:
        return float(m.group(1).replace(",", ".")) / 100
    return None if re.search(r"mixte", str(h or ""), re.I) else 0.0


def iso(v):
    if isinstance(v, dt.datetime):
        return v.date().isoformat()
    if isinstance(v, dt.date):
        return v.isoformat()
    if isinstance(v, (int, float)) and 20000 < v < 80000:     # date Excel en nombre de jours
        return (dt.date(1899, 12, 30) + dt.timedelta(days=int(v))).isoformat()
    if isinstance(v, str):
        m = re.match(r"(\d{4})-(\d\d)-(\d\d)", v) or re.match(r"(\d\d)/(\d\d)/(\d{4})", v)
        if m:
            g = m.groups()
            return f"{g[0]}-{g[1]}-{g[2]}" if len(g[0]) == 4 else f"{g[2]}-{g[1]}-{g[0]}"
    return None


# ───────────── Grand livre et plan de comptes (fichier LPP) ─────────────
def grand_livre(wbv, annee=None):
    """Écritures de l'onglet GRAND LIVRE. Mêmes règles que l'import du dashboard (statut d'après le commentaire)."""
    ws = wbv["GRAND LIVRE"]
    out, prev = [], None
    for r in ws.iter_rows(min_row=5, values_only=True):
        compte = str(r[0]).strip() if r[0] is not None else ""
        if not re.fullmatch(r"\d{6}", compte):
            continue
        d = iso(r[4]) or prev
        if not d:
            continue
        prev = d
        if annee and not d.startswith(str(annee)):
            continue
        deb, cre = num(r[8]) or 0.0, num(r[9]) or 0.0
        if not deb and not cre:
            continue
        t = taux(r[7])
        ht = deb or cre
        tva = abs(num(r[11])) if num(r[11]) is not None else round(ht * (t or 0), 2)
        com = str(r[13] or "")
        statut = ("provisoire" if re.search(r"PROVISOIRE", com, re.I)
                  else "a_verifier" if re.search(r"estim|[aà] confirmer|[aà] v[ée]rifier", com, re.I) else "ok")
        out.append({"date": d, "compte": compte, "fournisseur": str(r[2] or "").strip()[:120], "libelle": str(r[3] or "").strip()[:200],
                    "taux": t, "sens": "C" if cre and not deb else "D", "ht": round(ht, 2), "tva": round(tva, 2),
                    "commentaire": com[:500], "statut": statut, "source": "ca" if compte.startswith("7") else "grand_livre"})
    return out


def plan(wbv):
    ws = wbv["BDD"]
    out = {}
    for r in ws.iter_rows(min_row=4, values_only=True):
        c = str(r[0]).strip() if r[0] is not None else ""
        if re.fullmatch(r"\d{6}", c):
            out[c] = {"compte": c, "libelle": str(r[1] or "")[:200], "rgpmt1": str(r[2] or "")[:120],
                      "rgpmt2": str(r[3] or "")[:120], "rgpmt3": str(r[4] or "")[:120]}
    return list(out.values())


# ───────────── Business plan (fichier « avec TVA - AVENANT … ») ─────────────
# Sections de l'onglet Projection : libellé de l'en-tête (colonne B) → rubrique des lignes qui suivent
SECTIONS = [
    (r"^chiffre d.affaires$", "ca"),
    (r"^marge brute", None),
    (r"^redevances de franchise \(part variable", "franchise"),
    (r"^marge apr[eè]s", None),
    (r"^co[uû]ts people \(int[ée]rimaires", "interim"),
    (r"^marge sur co[uû]ts directs", None),
    (r"^co[uû]ts structure", "structure"),
    (r"^co[uû]ts people \(personnel salari", "ms"),
    (r"^redevances de franchise \(part fixe", "franchise"),
    (r"^co[uû]ts fixes", None),
    (r"^ebe$", None),
]
RUBRIQUES = ("ca", "achats", "franchise", "interim", "structure", "ms")


def bp(wbv, wbf):
    """{mois 'AAAA-MM': {ca, achats, franchise, interim, structure, ms, dap, fin, reel}} (charges en positif)."""
    ev = Evaluateur(wbv, wbf)
    out = {}
    for name in wbv.sheetnames:
        m = re.fullmatch(r"Projection (\d{4})", name)
        if not m:
            continue
        an = int(m.group(1))
        ws = wbf[name]
        # ligne des mois (dates de janvier à décembre) et ligne Réel / Projection juste en dessous
        hdr = next((r for r in range(1, 40) if isinstance(wbv[name].cell(r, 4).value, dt.datetime)
                    and re.match(r"(r[ée]el|projection)", str(wbv[name].cell(r + 1, 4).value or ""), re.I)), None)
        if not hdr:
            continue
        cols = [c for c in range(4, 16) if isinstance(wbv[name].cell(hdr, c).value, dt.datetime)]
        statut = {c: str(wbv[name].cell(hdr + 1, c).value or "") for c in cols}
        rub, lignes = None, {k: [] for k in RUBRIQUES}
        dap_row = fin_row = None
        for r in range(hdr + 2, ws.max_row + 1):
            lab = str(ws.cell(r, 2).value or "").strip()
            low = lab.lower()
            if not lab:
                continue
            sec = next((k for p, k in SECTIONS if re.search(p, low)), "—")
            if sec != "—":
                rub = sec
                continue
            if low.startswith("dap"):
                dap_row = r
                rub = None
                continue
            if low.startswith("charges financi") and fin_row is None:
                fin_row = r
                continue
            if low.startswith(("résultat", "resultat", "point mort")) or re.match(r"imp[ôo]ts? sur les soc", low):
                rub = None
                continue
            if rub == "ca" and low.startswith("achats"):
                lignes["achats"].append(r)
            elif rub:
                lignes[rub].append(r)
        for c in cols:
            k = f"{an}-{wbv[name].cell(hdr, c).value.month:02d}"
            o = {"reel": statut[c].strip().lower().startswith("r")}
            for rb in RUBRIQUES:
                vals = [ev.val(name, c, r) for r in lignes[rb]]
                tot = sum(v for v in vals if v is not None)
                o[rb] = round(tot if rb == "ca" else -tot, 2)
                o[rb + "_incomplet"] = any(v is None for v in vals)
            if dap_row:   # le montant est parfois une ligne plus bas (libellé sur deux lignes)
                vide = lambda r: ws.cell(r, c).value in (None, "") and wbv[name].cell(r, c).value in (None, "")
                v = ev.val(name, c, dap_row + 1 if vide(dap_row) else dap_row)
                o["dap"] = round(-(v or 0.0), 2)
            if fin_row:
                o["fin"] = round(-(ev.val(name, c, fin_row) or 0.0), 2)
            out[k] = o
    return out


def lire(path_or_bytes):
    """Ouvre un classeur (chemin ou contenu) et dit ce qu'il contient : ('grand_livre'|'bp'|None, wbv, wbf)."""
    import io
    import openpyxl
    src = io.BytesIO(path_or_bytes) if isinstance(path_or_bytes, (bytes, bytearray)) else path_or_bytes
    wbv = openpyxl.load_workbook(src, data_only=True)
    if isinstance(src, io.BytesIO):
        src.seek(0)
    wbf = openpyxl.load_workbook(src, data_only=False)
    names = set(wbv.sheetnames)
    if "GRAND LIVRE" in names:
        return "grand_livre", wbv, wbf
    if any(re.fullmatch(r"Projection \d{4}", n) for n in names):
        return "bp", wbv, wbf
    return None, wbv, wbf


if __name__ == "__main__":   # essai local : python3 rodolph_excel.py fichier.xlsx
    import sys
    for p in sys.argv[1:]:
        kind, wbv, wbf = lire(p)
        print("──", p, "→", kind)
        if kind == "grand_livre":
            e = grand_livre(wbv, 2026)
            print(len(e), "écritures 2026,", len(plan(wbv)), "comptes ; dernière date", max(x["date"] for x in e))
        elif kind == "bp":
            for k, o in sorted(bp(wbv, wbf).items()):
                ebe = o["ca"] - sum(o[r] for r in RUBRIQUES[1:])
                inc = [r for r in RUBRIQUES if o[r + "_incomplet"]]
                print(k, "réel " if o["reel"] else "prév.", *(f"{o[r]:9.0f}" for r in RUBRIQUES), f"EBE {ebe:9.0f}",
                      f"DAP {o.get('dap', 0):6.0f} fin {o.get('fin', 0):6.0f}", ("incomplet: " + ",".join(inc)) if inc else "")
