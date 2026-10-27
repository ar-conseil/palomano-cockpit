#!/usr/bin/env python3
"""
Connexion Microsoft du robot, à faire une fois (et à refaire si la session expire).

Affiche un code à saisir sur https://microsoft.com/devicelogin avec le compte lille@palomano.com,
puis enregistre le jeton de session dans le secret GitHub MS_REFRESH_TOKEN (sans jamais l'afficher)
et vérifie que les 3 fichiers sont lisibles.

Usage :  python3 connect_microsoft.py
"""
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from fetch_sharepoint import CLIENT_ID, DRIVE_ID, FILES, FOLDER, SCOPE, TENANT_ID, TOKEN_URL

REPO = "ar-conseil/palomano-cockpit"


def post(url, fields):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(fields).encode())
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)


def main():
    dc = post(f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/devicecode",
              {"client_id": CLIENT_ID, "scope": SCOPE})
    if "user_code" not in dc:
        sys.exit(f"Erreur Microsoft : {dc.get('error_description', dc)}")
    print(f"\n👉 Ouvrez {dc['verification_uri']} et saisissez le code : {dc['user_code']}\n"
          f"   Connectez-vous avec lille@palomano.com (code valable {dc['expires_in'] // 60} min).\n", flush=True)

    deadline = time.time() + dc["expires_in"]
    while time.time() < deadline:
        time.sleep(dc.get("interval", 5))
        tok = post(TOKEN_URL, {"client_id": CLIENT_ID, "device_code": dc["device_code"],
                               "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
        if "access_token" in tok:
            break
        if tok.get("error") not in ("authorization_pending", "slow_down"):
            sys.exit(f"Connexion refusée : {tok.get('error')} — {tok.get('error_description', '').splitlines()[0]}")
    else:
        sys.exit("Code expiré, relancez le script.")

    # Vérifie l'accès aux fichiers avant d'enregistrer quoi que ce soit
    for name in FILES:
        url = f"https://graph.microsoft.com/v1.0/drives/{DRIVE_ID}/root:/{urllib.parse.quote(f'{FOLDER}/{name}')}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok['access_token']}"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                meta = json.load(r)
            print(f"✓ {name} lisible ({meta['size']:,} octets, modifié {meta['lastModifiedDateTime']})")
        except urllib.error.HTTPError as e:
            sys.exit(f"✗ {name} : accès refusé (HTTP {e.code})")

    subprocess.run(["gh", "secret", "set", "MS_REFRESH_TOKEN", "-R", REPO],
                   input=tok["refresh_token"].encode(), check=True, capture_output=True)
    print("\n✓ Jeton de session enregistré dans GitHub (secret MS_REFRESH_TOKEN).")


if __name__ == "__main__":
    main()
