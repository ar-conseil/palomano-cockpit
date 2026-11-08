#!/usr/bin/env python3
"""
Synchronise le suivi de facturation Écoles & Centres entre l'Excel SharePoint
(« PARC/ÉCOLES & CENTRES/SUIVI FACTURATION ECOLES CENTRES*.xlsx », onglets par année)
et l'espace équipe (table Supabase factures_groupes).

- Excel → site : chaque ligne (clé : n° de facture) est recopiée, sauf si elle a été modifiée
  sur le site depuis la dernière synchronisation.
- Site → Excel : les lignes modifiées ou créées sur le site (« dirty ») sont écrites dans l'Excel,
  colonnes A à O uniquement (les formules d'ancienneté et de tri ne sont jamais touchées).
  Il faut pour cela l'autorisation Microsoft Files.ReadWrite.All ; sans elle, les modifications
  restent en attente et le site l'indique.

Variables : SUPABASE_URL, SUPABASE_SERVICE_KEY, plus celles de fetch_sharepoint.py.
"""
import datetime as dt
import io
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

import openpyxl

import fetch_sharepoint as fs

FOLDER = "PARC/ÉCOLES & CENTRES"
PREFIX = "SUIVI FACTURATION"
FIRST_ROW = 5
COLS = ["date_facture", "organisme", "numero", "montant_ttc", "statut", "date_encaissement", "mode",
        "libelle_releve", "fiabilite", "commentaire", "envoi_mail", "depot_chorus", "relance1", "relance2",
        "prochaine_action"]                       # colonnes A à O
DATES = {"date_facture", "date_encaissement", "relance1", "relance2"}
SB_URL, SB_KEY = os.environ.get("SUPABASE_URL", "").rstrip("/"), os.environ.get("SUPABASE_SERVICE_KEY", "")


def sb(path, body=None, method="GET", prefer="return=minimal"):
    req = urllib.request.Request(f"{SB_URL}/rest/v1/{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}",
                                          "Content-Type": "application/json", "Prefer": prefer})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def to_date(v):
    if isinstance(v, dt.datetime):
        return v.date()
    if isinstance(v, dt.date):
        return v
    if isinstance(v, str) and v.strip():
        t = v.strip()
        for f in ("%d/%m/%y", "%d/%m/%Y", "%m/%d/%Y", "%Y-%m-%d"):
            try:
                return dt.datetime.strptime(t, f).date()
            except ValueError:
                pass
    return None


def norm(field, v):
    if field in DATES:
        d = to_date(v)
        return d.isoformat() if d else None
    if field == "montant_ttc":
        return round(float(v), 2) if isinstance(v, (int, float)) else None
    if field == "numero":
        return str(int(v)) if isinstance(v, float) and v.is_integer() else str(v or "").strip()
    return "" if v is None else str(v).strip()


def excel_value(field, v):
    """Valeur à écrire dans l'Excel : dates en numéro de série (le format de la cellule est conservé)."""
    if field in DATES:
        return (dt.date.fromisoformat(v) - dt.date(1899, 12, 30)).days if v else ""
    if field == "montant_ttc":
        return v if v is not None else ""
    if field == "numero":
        return int(v) if (v or "").isdigit() and len(v) < 16 else (v or "")
    return v or ""


def find_workbook(tok):
    url = (f"https://graph.microsoft.com/v1.0/drives/{fs.DRIVE_ID}/root:/{urllib.parse.quote(FOLDER)}:/children"
           "?$select=id,name,lastModifiedDateTime&$top=200")
    with fs.graph(url, tok) as r:
        items = [i for i in json.load(r)["value"] if i["name"].upper().startswith(PREFIX) and i["name"].endswith(".xlsx")]
    if not items:
        sys.exit("Facturation : fichier « SUIVI FACTURATION… » introuvable dans PARC/ÉCOLES & CENTRES")
    item = max(items, key=lambda i: i["lastModifiedDateTime"])
    with fs.graph(f"https://graph.microsoft.com/v1.0/drives/{fs.DRIVE_ID}/items/{item['id']}/content", tok) as r:
        return item, r.read()


def read_excel(data):
    wb = openpyxl.load_workbook(io.BytesIO(data), data_only=True)
    rows, empty = {}, {}
    for ws in wb.worksheets:
        if not (ws.title.isdigit() and len(ws.title) == 4):
            continue
        first_empty = None
        for r in range(FIRST_ROW, ws.max_row + 1):
            vals = [ws.cell(r, c + 1).value for c in range(len(COLS))]
            rec = {f: norm(f, v) for f, v in zip(COLS, vals)}
            if not rec["organisme"] and not rec["numero"]:
                first_empty = first_empty or r
                continue
            if rec["numero"]:
                rec.update(annee=int(ws.title), excel_row=r)
                rows[rec["numero"]] = rec
        empty[ws.title] = first_empty or ws.max_row + 1
    return rows, empty


def write_row(tok, item_id, sheet, r, rec):
    base = f"https://graph.microsoft.com/v1.0/drives/{fs.DRIVE_ID}/items/{item_id}/workbook/worksheets('{urllib.parse.quote(sheet)}')"
    values = [[excel_value(f, rec.get(f)) for f in COLS]]
    req = urllib.request.Request(f"{base}/range(address='A{r}:O{r}')", method="PATCH",
                                 data=json.dumps({"values": values}).encode(),
                                 headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=60).read()


def main():
    if not SB_URL or not SB_KEY:
        print("Facturation : secrets Supabase absents, synchronisation ignorée")
        return
    tok = fs.access_token()
    item, data = find_workbook(tok)
    excel, empty = read_excel(data)
    db = {r["numero"]: r for r in sb("factures_groupes?select=*", prefer="")}
    now = dt.datetime.now(dt.timezone.utc).isoformat()

    # 1) Site → Excel
    pending = [r for r in db.values() if r["dirty"]]
    written, blocked = 0, None
    for rec in pending:
        sheet = str(rec["annee"])
        if sheet not in empty:
            continue
        row = rec["excel_row"] or (excel.get(rec["numero"]) or {}).get("excel_row") or empty[sheet]
        try:
            write_row(tok, item["id"], sheet, row, rec)
        except urllib.error.HTTPError as e:
            blocked = f"écriture dans l'Excel refusée (HTTP {e.code}) : autorisation Microsoft « lecture et écriture » à accorder"
            break
        if not rec["excel_row"] and row == empty[sheet]:
            empty[sheet] += 1
        sb(f"factures_groupes?numero=eq.{urllib.parse.quote(rec['numero'])}&updated_at=eq.{urllib.parse.quote(rec['updated_at'])}",
           {"dirty": False, "excel_row": row, "synced_at": now}, "PATCH")
        excel[rec["numero"]] = {**rec, "excel_row": row}
        written += 1

    # 2) Excel → site (sans écraser une modification du site en attente)
    changed = 0
    for n, rec in excel.items():
        cur = db.get(n)
        if cur and cur["dirty"]:
            continue
        payload = {**{f: rec[f] for f in COLS}, "annee": rec["annee"], "excel_row": rec["excel_row"]}
        if cur and all(cur.get(k) == v or (k == "montant_ttc" and cur.get(k) is not None and v is not None
                                           and abs(float(cur[k]) - float(v)) < 0.005) for k, v in payload.items()):
            continue
        payload.update(dirty=False, synced_at=now)
        if cur:
            sb(f"factures_groupes?numero=eq.{urllib.parse.quote(n)}&dirty=is.false", payload, "PATCH")
        else:
            sb("factures_groupes", payload, "POST")
        changed += 1

    left = len(pending) - written
    msg = (f"{len(excel)} factures lues dans « {item['name']} » · {changed} mises à jour sur le site · "
           f"{written} écrites dans l'Excel" + (f" · {left} en attente : {blocked}" if blocked else ""))
    sb("sync_state?on_conflict=key", [{"key": "facturation", "ok": not blocked, "message": msg, "synced_at": now}],
       "POST", "resolution=merge-duplicates,return=minimal")
    print("Facturation : " + msg)


if __name__ == "__main__":
    main()
