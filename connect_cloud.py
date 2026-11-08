#!/usr/bin/env python3
"""
Connexion Microsoft du robot, lancée depuis GitHub (onglet Actions › « Connexion Microsoft » › Run workflow).
Affiche dans le journal du job un code à saisir sur https://microsoft.com/devicelogin avec lille@palomano.com,
puis enregistre la session (chiffrée) dans le cache GitHub utilisé par l'actualisation. Aucun Mac nécessaire.
"""
import json
import sys
import time
import urllib.parse

import fetch_sharepoint as fs
from connect_microsoft import post


def main():
    dc = post(f"https://login.microsoftonline.com/{fs.TENANT_ID}/oauth2/v2.0/devicecode",
              {"client_id": fs.CLIENT_ID, "scope": fs.SCOPE})
    if "user_code" not in dc:
        sys.exit(f"Erreur Microsoft : {dc.get('error_description', dc)}")
    print(f"::notice title=Code de connexion Microsoft::Ouvrez {dc['verification_uri']} et saisissez {dc['user_code']} "
          f"(compte lille@palomano.com, valable {dc['expires_in'] // 60} min)", flush=True)
    deadline = time.time() + dc["expires_in"]
    while time.time() < deadline:
        time.sleep(dc.get("interval", 5))
        tok = post(fs.TOKEN_URL, {"client_id": fs.CLIENT_ID, "device_code": dc["device_code"],
                                  "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
        if "access_token" in tok:
            break
        if tok.get("error") not in ("authorization_pending", "slow_down"):
            sys.exit(f"Connexion refusée : {tok.get('error')}")
    else:
        sys.exit("Code expiré, relancez le workflow.")
    for name in fs.FILES:
        url = f"https://graph.microsoft.com/v1.0/drives/{fs.DRIVE_ID}/root:/{urllib.parse.quote(f'{fs.FOLDER}/{name}')}"
        with fs.graph(url, tok["access_token"]) as r:
            print(f"✓ {name} lisible ({json.load(r)['size']:,} octets)")
    fs.save_cached(tok["refresh_token"])
    print(f"✓ Session Microsoft enregistrée (droits : {tok.get('scope', fs.SCOPE)})")


if __name__ == "__main__":
    main()
