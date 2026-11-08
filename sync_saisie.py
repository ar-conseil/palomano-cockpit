#!/usr/bin/env python3
"""
Recopie les résultats du jour saisis sur l'espace équipe (table Supabase saisie_jour)
dans « PARC/SUIVI PARC/Objectifs Palomano Lille.xlsx », onglet du mois (« Novembre 26 »…),
ligne du jour (ligne 8 + jour du mois), dans les seules colonnes de saisie du tableau :

  F G      ENTRÉE PARC   TTC, nb entrées
  J K L    ANNIVERSAIRE  TTC, nb entrées, nb anniv
  O P      SCOLAIRE      TTC, nb entrées
  S T      GROUPE/CENTRE TTC, nb entrées
  V W      SNACKING      HT, TTC
  Y Z      BOUTIQUE      HT, TTC
  AC       ÉVÈNEMENT     TTC

Les colonnes calculées (HT, totaux, objectifs) ne sont jamais touchées : Excel recalcule.
Lancé avant fetch_sharepoint.py, pour que le dashboard lise le fichier à jour.
Il faut l'autorisation Microsoft Files.ReadWrite.All (variable MS_SCOPE).

Variables : SUPABASE_URL, SUPABASE_SERVICE_KEY, plus celles de fetch_sharepoint.py.
"""
import datetime as dt
import json
import os
import urllib.error
import urllib.parse
import urllib.request

import fetch_sharepoint as fs

PATH = "PARC/SUIVI PARC/Objectifs Palomano Lille.xlsx"
MONTHS = ["Janvier", "Février", "Mars", "Avril", "Mai", "Juin", "Juillet", "Aout", "Septembre", "Octobre",
          "Novembre", "Décembre"]
RANGES = [("F", "G", ["parc_ttc", "parc_nb"]), ("J", "L", ["anniv_ttc", "anniv_entrees", "anniv_nb"]),
          ("O", "P", ["scolaire_ttc", "scolaire_nb"]), ("S", "T", ["groupe_ttc", "groupe_nb"]),
          ("V", "W", ["snack_ht", "snack_ttc"]), ("Y", "Z", ["boutique_ht", "boutique_ttc"]),
          ("AC", "AC", ["event_ttc"])]
SB_URL, SB_KEY = os.environ.get("SUPABASE_URL", "").rstrip("/"), os.environ.get("SUPABASE_SERVICE_KEY", "")


def sb(path, body=None, method="GET", prefer="return=minimal"):
    req = urllib.request.Request(f"{SB_URL}/rest/v1/{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}",
                                          "Content-Type": "application/json", "Prefer": prefer})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def graph(url, tok, body=None, method="GET"):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def sheet_of(d):
    return f"{MONTHS[d.month - 1]} {d.year % 100:02d}"


def serial(d):
    return (d - dt.date(1899, 12, 30)).days


def cell(v):
    if v is None:
        return ""
    f = float(v)
    return int(f) if f.is_integer() else round(f, 2)


def state(ok, msg):
    sb("sync_state?on_conflict=key", [{"key": "saisie", "ok": ok, "message": msg,
                                        "synced_at": dt.datetime.now(dt.timezone.utc).isoformat()}],
       "POST", "resolution=merge-duplicates,return=minimal")
    print("Saisie du jour : " + msg)


def main():
    if not SB_URL or not SB_KEY:
        print("Saisie du jour : secrets Supabase absents, recopie ignorée")
        return
    try:
        rows = sb("saisie_jour?dirty=is.true&select=*&order=date", prefer="")
    except urllib.error.HTTPError as e:
        print(f"::warning::Saisie du jour : table illisible (HTTP {e.code}) — schema_v8.sql exécuté ?")
        return
    if not rows:
        print("Saisie du jour : rien à recopier")
        return
    tok = fs.access_token()
    item = graph(f"https://graph.microsoft.com/v1.0/drives/{fs.DRIVE_ID}/root:/{urllib.parse.quote(PATH)}", tok)
    book = f"https://graph.microsoft.com/v1.0/drives/{fs.DRIVE_ID}/items/{item['id']}/workbook"
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    done, errors, blocked = [], [], None
    for rec in rows:
        d = dt.date.fromisoformat(rec["date"])
        ws = f"{book}/worksheets('{urllib.parse.quote(sheet_of(d))}')"
        r = 8 + d.day
        try:
            got = graph(f"{ws}/range(address='D{r}')", tok)["values"][0][0]
            if not isinstance(got, (int, float)) or int(got) != serial(d):
                raise ValueError(f"la ligne {r} de « {sheet_of(d)} » ne correspond pas au {d:%d/%m/%Y}")
            for a, b, fields in RANGES:
                graph(f"{ws}/range(address='{a}{r}:{b}{r}')", tok, {"values": [[cell(rec.get(f)) for f in fields]]}, "PATCH")
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                blocked = "écriture refusée par Microsoft : autorisation « lecture et écriture » à accorder"
                break
            if e.code == 404:
                err = f"onglet « {sheet_of(d)} » introuvable dans l'Excel"
            elif e.code in (409, 423):
                err = "fichier verrouillé, nouvel essai dans 30 min"
            else:
                err = f"erreur Microsoft HTTP {e.code}"
            errors.append(f"{d:%d/%m} : {err}")
            sb(f"saisie_jour?date=eq.{rec['date']}", {"sync_error": err}, "PATCH")
            continue
        except ValueError as e:
            errors.append(f"{d:%d/%m} : {e}")
            sb(f"saisie_jour?date=eq.{rec['date']}", {"sync_error": str(e)}, "PATCH")
            continue
        # ne marque « copié » que si personne n'a modifié la ligne entre-temps
        sb(f"saisie_jour?date=eq.{rec['date']}&updated_at=eq.{urllib.parse.quote(rec['updated_at'])}",
           {"dirty": False, "synced_at": now, "sync_error": None}, "PATCH")
        done.append(f"{d:%d/%m}")
    msg = (f"{len(done)} jour(s) recopié(s) dans « Objectifs Palomano Lille »" + (f" ({', '.join(done)})" if done else "")
           + (f" · en erreur : {' ; '.join(errors)}" if errors else "") + (f" · {blocked}" if blocked else ""))
    state(not errors and not blocked, msg)


if __name__ == "__main__":
    main()
