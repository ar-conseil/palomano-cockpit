#!/usr/bin/env python3
"""
Lecture de l'export caisse « palomano-la-maillerie__JJ.MM.AA__JJ.MM.AA.xlsx » (onglet 1.7 Détails des ventes).

Le fichier fait plus de 150 000 lignes et contient des cellules mal typées (n° de TVA en « nombre »)
qui font échouer openpyxl : on lit donc directement le XML de la feuille, en flux.
Seules les données agrégées sortent d'ici — aucun nom ni identifiant client.
"""
import datetime as dt
import re
import zipfile
from collections import defaultdict
from xml.etree.ElementTree import iterparse

NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
COL_RE = re.compile(r"[A-Z]+")


def _col(ref):
    n = 0
    for ch in COL_RE.match(ref).group():
        n = n * 26 + ord(ch) - 64
    return n - 1


def iter_rows(path, sheet="xl/worksheets/sheet1.xml"):
    """Lignes de la feuille sous forme de listes (texte ou float), sans passer par openpyxl."""
    with zipfile.ZipFile(path) as z, z.open(sheet) as f:
        row = {}
        for ev, el in iterparse(f, events=("end",)):
            tag = el.tag
            if tag == NS + "c":
                t = el.get("t")
                if t == "inlineStr":
                    v = "".join(x.text or "" for x in el.iter(NS + "t"))
                else:
                    x = el.find(NS + "v")
                    v = x.text if x is not None else None
                    if v is not None and t not in ("s", "str"):
                        try:
                            v = float(v)
                        except ValueError:
                            pass
                if v not in (None, ""):
                    row[_col(el.get("r"))] = v
                el.clear()
            elif tag == NS + "row":
                width = max(row) + 1 if row else 0
                yield [row.get(i) for i in range(width)]
                row = {}
                el.clear()


def num(v):
    return v if isinstance(v, float) else 0.0


def famille(cat):
    c = (cat or "").lower()
    if "snack" in c:
        return "snack"
    if "boutique" in c:
        return "boutique"
    if c.startswith("entrée au parc"):
        return "entrees"
    if "anniv" in c:
        return "anniv"
    if any(k in c for k in ("loisirs", "scolaire", "groupe", "assistante", "school")):
        return "b2b"
    if any(k in c for k in ("évèn", "évén", "evèn", "even", "atelier", "privatisation", "palo-bouh", "palo-boom")):
        return "event"
    return "autre"  # acomptes, bons cadeaux, avoirs


def read_ventes(path):
    """Agrégats journaliers par produit, tickets snack/boutique, heures de vente et codes postaux (HT)."""
    rows = iter_rows(path)
    head = next(rows)
    ix = {h: i for i, h in enumerate(head)}
    g = lambda r, k: r[ix[k]] if ix[k] < len(r) else None
    ht_cols = [ix[f"Montant HT Taux {n}"] for n in (1, 2, 3, 4)]

    products, pidx = [], {}
    pd = defaultdict(lambda: [0.0, 0.0])            # (jour, produit) → [qté, HT]
    tickets = defaultdict(lambda: defaultdict(set)) # jour → famille → n° de vente
    hour = defaultdict(lambda: [0.0, 0.0])          # (jour, heure) → [HT snack, HT boutique]
    cp = defaultdict(lambda: [set(), 0.0])          # (mois, CP) → [ventes, HT]

    for r in rows:
        if not r or g(r, "Vente supprimée le") or "annul" in str(g(r, "Statut") or "").lower():
            continue
        ts = g(r, "Enregistré le")
        cat = g(r, "Catégorie")
        if not isinstance(ts, str) or len(ts) < 13 or cat in (None, "Paiement"):
            continue
        d, h = ts[:10], int(ts[11:13])
        sous = g(r, "Sous-catégorie") or ""
        name = g(r, "Produit parent") or g(r, "Produit") or g(r, "Produit & Paiement")
        if not name:
            continue
        name = re.sub(r"^\[[^\]]*\]\s*", "", str(name)).strip()
        fam = famille(cat)
        if fam == "boutique":   # « Boutique Palo-Feu » / marque Klein
            group, brand = re.sub(r"(?i)^boutique\s*", "", cat).strip() or "Autre", sous
        else:
            group, brand = sous if sous and sous != "---" else cat, ""
        key = (fam, group, name)
        if key not in pidx:
            pidx[key] = len(products)
            products.append([fam, group, name, brand])
        ht = sum(num(r[i]) if i < len(r) else 0.0 for i in ht_cols)
        q = num(g(r, "Quantité"))
        sale = g(r, "Numéro de vente")

        e = pd[(d, pidx[key])]
        e[0] += q
        e[1] += ht
        if sale:
            tickets[d][fam].add(sale)
        if fam in ("snack", "boutique"):
            hour[(d, h)][0 if fam == "snack" else 1] += ht
        code = g(r, "Code postal")
        if code and sale:
            code = str(code).split(".")[0].strip()
            if code.isdigit():
                c = cp[(d[:7], code.zfill(5))]
                c[0].add(sale)
                c[1] += ht

    days = sorted({k[0] for k in pd})
    di = {d: i for i, d in enumerate(days)}
    r2 = lambda x: round(x, 2)
    return {
        "days": days,
        "products": products,                                       # [famille, groupe, produit, marque]
        "pd": [[di[d], p, round(v[0], 1), r2(v[1])] for (d, p), v in sorted(pd.items()) if v[0] or v[1]],
        "tk": {d: {f: len(s) for f, s in fs.items()} for d, fs in sorted(tickets.items())},
        "hr": [[di[d], h, r2(v[0]), r2(v[1])] for (d, h), v in sorted(hour.items()) if d in di and (v[0] or v[1])],
        "cp": [[m, c, len(v[0]), r2(v[1])] for (m, c), v in sorted(cp.items())],
    }


if __name__ == "__main__":
    import json
    import sys
    out = read_ventes(sys.argv[1])
    print(json.dumps({k: (v if k == "range" else len(v)) for k, v in out.items()}))
    print(len(json.dumps(out, ensure_ascii=False, separators=(",", ":"))) // 1024, "Ko")
