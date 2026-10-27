#!/usr/bin/env python3
"""
Télécharge les 3 fichiers du dossier SharePoint « PARC/SUIVI PARC » à partir de leurs liens
de partage « Tout le monde disposant du lien » (affichage seul).

Variables d'environnement (secrets GitHub) :
  SP_LINK_SUIVI     lien de « Objectifs Palomano Lille.xlsx »
  SP_LINK_YANNIKA   lien de « PALOMANO_Objectifs_Yannika.xlsx »
  SP_LINK_COLOR     lien de « Colorhisto_PALOMANO_Lille.xlsx »
  PALOMANO_SUIVI_DIR  dossier de destination (défaut : ./sources)

Usage :  python3 fetch_sharepoint.py
"""
import email.utils
import http.cookiejar
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

FILES = {
    "SP_LINK_SUIVI": "Objectifs Palomano Lille.xlsx",
    "SP_LINK_YANNIKA": "PALOMANO_Objectifs_Yannika.xlsx",
    "SP_LINK_COLOR": "Colorhisto_PALOMANO_Lille.xlsx",
}
DEST = Path(os.environ.get("PALOMANO_SUIVI_DIR", Path(__file__).resolve().parent / "sources"))


def download_url(link):
    """Un lien de partage SharePoint s'ouvre dans Excel en ligne ; download=1 renvoie le fichier brut."""
    parts = urllib.parse.urlsplit(link.strip())
    query = urllib.parse.parse_qsl(parts.query)
    query = [(k, v) for k, v in query if k != "download"] + [("download", "1")]
    return urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query)))


def main():
    missing = [k for k in FILES if not os.environ.get(k)]
    if missing:
        sys.exit(f"Secrets manquants : {', '.join(missing)} (à ajouter dans GitHub › Settings › Secrets › Actions)")
    DEST.mkdir(parents=True, exist_ok=True)
    errors = []
    for var, name in FILES.items():
        # Les liens anonymes SharePoint posent un cookie pendant la redirection : il faut le conserver.
        hops = []

        class Trace(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                hops.append(f"{code}→{urllib.parse.urlsplit(newurl).path[:28]}…")
                return super().redirect_request(req, fp, code, msg, headers, newurl)

        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), Trace())
        opener.addheaders = [("User-Agent", "Mozilla/5.0 (palomano-cockpit)")]
        try:
            with opener.open(download_url(os.environ[var]), timeout=60) as r:
                data, modified = r.read(), r.headers.get("Last-Modified")
                final = urllib.parse.urlsplit(r.geturl())
        except urllib.error.HTTPError as e:
            errors.append(f"« {name} » : HTTP {e.code} après {' '.join(hops) or 'aucune redirection'} — "
                          f"lien en « Tout le monde » et téléchargement autorisé ? ({var})")
            continue
        if not data.startswith(b"PK"):  # un .xlsx est une archive zip ; sinon c'est une page de connexion
            title = re.search(rb"<title>(.*?)</title>", data, re.S | re.I)
            errors.append(f"« {name} » : le lien ne renvoie pas le fichier mais la page "
                          f"« {title.group(1).decode(errors='replace').strip()[:60] if title else '?'} » "
                          f"({final.netloc}{final.path[:24]}…, redirections : {' '.join(hops) or 'aucune'}) — "
                          f"vérifiez qu'il est bien en « Tout le monde disposant du lien » ({var}).")
            continue
        (DEST / name).write_bytes(data)
        if modified:  # date de dernière modification SharePoint, affichée en pied de page du dashboard
            ts = email.utils.parsedate_to_datetime(modified).timestamp()
            os.utime(DEST / name, (ts, ts))
        print(f"↓ {name} ({len(data):,} octets, modifié {modified or 'date inconnue'})")
    if errors:
        sys.exit("\n".join(errors))


if __name__ == "__main__":
    main()
