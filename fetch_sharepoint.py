#!/usr/bin/env python3
"""
Télécharge les 3 fichiers du dossier SharePoint « PARC/SUIVI PARC » avec le compte Microsoft
de la direction (connexion déléguée, lecture seule : Files.Read.All).

La connexion initiale se fait une fois avec `connect_microsoft.py`, qui enregistre un jeton de
session (refresh token) dans le secret GitHub MS_REFRESH_TOKEN. À chaque passage, Microsoft
renvoie un nouveau jeton : il est conservé chiffré dans le cache GitHub Actions (MS_TOKEN_DIR)
pour que la session ne s'éteigne pas.

Variables d'environnement :
  MS_REFRESH_TOKEN    jeton de session initial (secret GitHub)
  DASH_PASSWORD       sert aussi à chiffrer le jeton renouvelé dans le cache
  MS_TOKEN_DIR        dossier du jeton renouvelé (défaut : ./.ms_token)
  PALOMANO_SUIVI_DIR  dossier de destination (défaut : ./sources)

Usage :  python3 fetch_sharepoint.py
"""
import base64
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

HERE = Path(__file__).resolve().parent
TENANT_ID = os.environ.get("MS_TENANT_ID", "bf94cc2f-302e-4f51-be78-91587215f19f")
CLIENT_ID = os.environ.get("MS_CLIENT_ID", "a2d397f3-628b-4b0e-b17f-fb9b5c1f2d99")  # appli « Palomano Cockpit »
SCOPE = "https://graph.microsoft.com/Files.Read.All offline_access"
DRIVE_ID = os.environ.get("SP_DRIVE_ID", "b!bSAxO8uBfEadDgDaxczJN3YHKcBl_Z5DpNXmbSfpraw3VfTDsgUSQbsRyhS9FVHu")
FOLDER = os.environ.get("SP_FOLDER", "PARC/SUIVI PARC")
FILES = ["Objectifs Palomano Lille.xlsx", "PALOMANO_Objectifs_Yannika.xlsx", "Colorhisto_PALOMANO_Lille.xlsx"]
DEST = Path(os.environ.get("PALOMANO_SUIVI_DIR", HERE / "sources"))
TOKEN_FILE = Path(os.environ.get("MS_TOKEN_DIR", HERE / ".ms_token")) / "refresh_token.enc"
TOKEN_URL = f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token"


def _key():
    pw = os.environ.get("DASH_PASSWORD")
    if not pw:
        return None
    return PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=b"palomano-ms-refresh-token",
                      iterations=200_000).derive(pw.encode())


def load_cached():
    key = _key()
    if not key or not TOKEN_FILE.exists():
        return None
    try:
        raw = base64.b64decode(TOKEN_FILE.read_text())
        return AESGCM(key).decrypt(raw[:12], raw[12:], None).decode()
    except Exception:
        return None


def save_cached(token):
    key = _key()
    if not key:
        return
    iv = os.urandom(12)
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(base64.b64encode(iv + AESGCM(key).encrypt(iv, token.encode(), None)).decode())


def redeem(refresh_token):
    body = urllib.parse.urlencode({"client_id": CLIENT_ID, "grant_type": "refresh_token",
                                   "refresh_token": refresh_token, "scope": SCOPE}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(TOKEN_URL, data=body), timeout=30) as r:
            return json.load(r), None
    except urllib.error.HTTPError as e:
        try:
            err = json.load(e)
            return None, f"{err.get('error')} — {err.get('error_description', '').splitlines()[0][:160]}"
        except Exception:
            return None, f"HTTP {e.code}"


def access_token():
    candidates = [("cache", load_cached()), ("secret", os.environ.get("MS_REFRESH_TOKEN"))]
    problems = []
    for origin, rt in candidates:
        if not rt:
            continue
        tok, err = redeem(rt)
        if tok:
            if tok.get("refresh_token"):
                save_cached(tok["refresh_token"])
            print(f"Connexion Microsoft OK (jeton du {origin})")
            return tok["access_token"]
        problems.append(f"{origin} : {err}")
    sys.exit("Connexion Microsoft impossible — relancez « python3 connect_microsoft.py » sur le Mac.\n"
             + ("\n".join(problems) or "Aucun jeton (secret MS_REFRESH_TOKEN manquant)."))


def graph(url, tok):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"}), timeout=60)


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    tok = access_token()
    for name in FILES:
        item = f"https://graph.microsoft.com/v1.0/drives/{DRIVE_ID}/root:/{urllib.parse.quote(f'{FOLDER}/{name}')}"
        try:
            with graph(item + ":/content", tok) as r:
                data = r.read()
            with graph(item, tok) as r:
                modified = json.load(r)["lastModifiedDateTime"]
        except urllib.error.HTTPError as e:
            sys.exit(f"Échec du téléchargement de « {name} » : HTTP {e.code} {e.read()[:200]!r}")
        (DEST / name).write_bytes(data)
        ts = dt.datetime.fromisoformat(modified.replace("Z", "+00:00")).timestamp()
        os.utime(DEST / name, (ts, ts))  # date SharePoint, affichée en pied de page du dashboard
        print(f"↓ {name} ({len(data):,} octets, modifié {modified})")


if __name__ == "__main__":
    main()
