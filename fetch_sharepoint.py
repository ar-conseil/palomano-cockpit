#!/usr/bin/env python3
"""
Télécharge les 3 fichiers du dossier SharePoint « PARC/SUIVI PARC » via Microsoft Graph
(application Entra ID, accès en lecture seule).

Variables d'environnement :
  AZ_TENANT_ID, AZ_CLIENT_ID, AZ_CLIENT_SECRET   identifiants de l'application Entra ID
  SP_DRIVE_ID      bibliothèque « Documents » du site PALOMANO LA MAILLERIE (valeur par défaut ci-dessous)
  SP_FOLDER        dossier dans la bibliothèque (défaut : PARC/SUIVI PARC)
  PALOMANO_SUIVI_DIR  dossier de destination (défaut : ./sources)

Usage :  python3 fetch_sharepoint.py
"""
import datetime as dt
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

FILES = ["Objectifs Palomano Lille.xlsx", "PALOMANO_Objectifs_Yannika.xlsx", "Colorhisto_PALOMANO_Lille.xlsx"]
DRIVE_ID = os.environ.get("SP_DRIVE_ID", "b!bSAxO8uBfEadDgDaxczJN3YHKcBl_Z5DpNXmbSfpraw3VfTDsgUSQbsRyhS9FVHu")
FOLDER = os.environ.get("SP_FOLDER", "PARC/SUIVI PARC")
DEST = Path(os.environ.get("PALOMANO_SUIVI_DIR", Path(__file__).resolve().parent / "sources"))


def token():
    names = ("AZ_TENANT_ID", "AZ_CLIENT_ID", "AZ_CLIENT_SECRET")
    missing = [k for k in names if not os.environ.get(k)]
    if missing:
        sys.exit(f"Secrets manquants : {', '.join(missing)} (à définir avec « gh secret set »)")
    tenant, cid, secret = (os.environ[k] for k in names)
    body = urllib.parse.urlencode({
        "client_id": cid, "client_secret": secret, "grant_type": "client_credentials",
        "scope": "https://graph.microsoft.com/.default",
    }).encode()
    req = urllib.request.Request(f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token", data=body)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["access_token"]


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    tok = token()
    for name in FILES:
        path = urllib.parse.quote(f"{FOLDER}/{name}")
        url = f"https://graph.microsoft.com/v1.0/drives/{DRIVE_ID}/root:/{path}:/content"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
        except urllib.error.HTTPError as e:
            sys.exit(f"Échec du téléchargement de « {name} » : HTTP {e.code} {e.read()[:300]!r}")
        (DEST / name).write_bytes(data)
        # Date de dernière modification SharePoint, affichée en pied de page du dashboard
        meta_req = urllib.request.Request(url[: -len(":/content")], headers={"Authorization": f"Bearer {tok}"})
        with urllib.request.urlopen(meta_req, timeout=30) as r:
            modified = json.load(r)["lastModifiedDateTime"]
        ts = dt.datetime.fromisoformat(modified.replace("Z", "+00:00")).timestamp()
        os.utime(DEST / name, (ts, ts))
        print(f"↓ {name} ({len(data):,} octets, modifié {modified})")


if __name__ == "__main__":
    main()
