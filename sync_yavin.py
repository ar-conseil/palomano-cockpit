#!/usr/bin/env python3
"""
Total des paiements carte du terminal Yavin, jour par jour, pour le bilan du jour (table Supabase yavin_jour).

API Webservices Yavin (docs.yavin.com/docs/webservices-api) :
  POST https://api.yavin.com/api/v5/pos/transactions/   en-tête « Yavin-Secret: <clé API> »
  corps JSON : startDate / endDate (AAAA-MM-JJ, inclus), timezone, limit (≤ 200), offset
  réponse : {"total", "limit", "offset", "count", "transactions": [{"amount" (centimes), "giftAmount" (centimes),
            "status": ok|ko|pending, "type": debit|credit, "createdAt", "serialNumber", ...}]}
La clé se trouve dans my.yavin.com, onglet API (secret GitHub YAVIN_API_KEY ; YAVIN_SERIALS facultatif :
numéros de série des terminaux du parc, séparés par des virgules).

On relit aujourd'hui et les 2 jours précédents à chaque passage (paiements tardifs, remboursements).
Variables : YAVIN_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_KEY.
"""
import datetime as dt
import json
import os
import time
import urllib.error
import urllib.request
from zoneinfo import ZoneInfo

URL = "https://api.yavin.com/api/v5/pos/transactions/"
KEY = os.environ.get("YAVIN_API_KEY", "").strip()
SERIALS = [s.strip() for s in os.environ.get("YAVIN_SERIALS", "").split(",") if s.strip()]
SB_URL, SB_KEY = os.environ.get("SUPABASE_URL", "").rstrip("/"), os.environ.get("SUPABASE_SERVICE_KEY", "")
DAYS = 3


def sb(path, body=None, method="GET", prefer="return=minimal"):
    req = urllib.request.Request(f"{SB_URL}/rest/v1/{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}",
                                          "Content-Type": "application/json", "Prefer": prefer})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def state(ok, msg):
    sb("sync_state?on_conflict=key", [{"key": "yavin", "ok": ok, "message": msg,
                                        "synced_at": dt.datetime.now(dt.timezone.utc).isoformat()}],
       "POST", "resolution=merge-duplicates,return=minimal")
    print("Yavin : " + msg)


def fetch_day(day):
    """Toutes les transactions d'une journée (pagination par 200, nouvel essai sur erreur 502)."""
    out, offset = [], 0
    while True:
        body = {"startDate": day.isoformat(), "endDate": day.isoformat(), "startTime": "00:00:00",
                "endTime": "23:59:59", "timezone": "Europe/Paris", "limit": 200, "offset": offset}
        if SERIALS:
            body["serialNumbers"] = SERIALS
        req = urllib.request.Request(URL, method="POST", data=json.dumps(body).encode(),
                                     headers={"Yavin-Secret": KEY, "Content-Type": "application/json",
                                              "User-Agent": "PalomanoDashboard"})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    page = json.load(r)
                break
            except urllib.error.HTTPError as e:
                if e.code == 502 and attempt < 3:
                    time.sleep(2 ** attempt)
                    continue
                raise
        rows = page.get("transactions") or []
        out += rows
        offset += len(rows)
        if not rows or offset >= int(page.get("total") or 0):
            return out


def main():
    if not SB_URL or not SB_KEY:
        print("Yavin : secrets Supabase absents, ignoré")
        return
    if not KEY:
        print("Yavin : clé API absente (secret YAVIN_API_KEY), ignoré")
        return
    today = dt.datetime.now(ZoneInfo("Europe/Paris")).date()
    rows, total_tx = [], 0
    try:
        for i in range(DAYS):
            day = today - dt.timedelta(days=i)
            tx = fetch_day(day)
            total_tx += len(tx)
            ok = [t for t in tx if str(t.get("status", "")).lower() == "ok"]
            cents = lambda t: int(t.get("amount") or 0) + int(t.get("giftAmount") or 0)
            debit = [t for t in ok if str(t.get("type", "debit")).lower() != "credit"]
            credit = [t for t in ok if str(t.get("type", "")).lower() == "credit"]
            rows.append({"date": day.isoformat(), "cb_total": round(sum(map(cents, debit)) / 100, 2), "nb": len(debit),
                         "rembourse": round(sum(map(cents, credit)) / 100, 2),
                         "nb_refus": sum(1 for t in tx if str(t.get("status", "")).lower() == "ko"),
                         "synced_at": dt.datetime.now(dt.timezone.utc).isoformat()})
    except urllib.error.HTTPError as e:
        state(False, f"API Yavin : erreur {e.code}" + (" (clé API refusée ?)" if e.code in (401, 403) else ""))
        return
    except Exception as e:
        state(False, f"API Yavin injoignable : {e}")
        return
    sb("yavin_jour?on_conflict=date", rows, "POST", "resolution=merge-duplicates,return=minimal")
    r0 = rows[0]
    state(True, f"aujourd'hui {r0['cb_total']:.2f} € en {r0['nb']} paiement(s) carte · {total_tx} transactions lues sur {DAYS} jours")


if __name__ == "__main__":
    main()
