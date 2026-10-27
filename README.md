# Palomano Cockpit

Tableau de bord de pilotage de Palomano Lille (parc La Maillerie).

Toutes les 30 minutes, GitHub Actions :
1. télécharge les 3 fichiers du dossier SharePoint `PARC/SUIVI PARC` via leurs liens de partage en affichage seul (`fetch_sharepoint.py`) ;
2. génère le dashboard (`build_dashboard.py` + `template.html`) ;
3. le chiffre avec le mot de passe de l'équipe (`encrypt_page.py`, AES-256-GCM) et le publie sur GitHub Pages.

Aucune donnée n'est stockée dans ce dépôt : seule la page chiffrée est publiée.

Secrets du dépôt : `SP_LINK_SUIVI`, `SP_LINK_YANNIKA`, `SP_LINK_COLOR` (liens de partage) et `DASH_PASSWORD`.
Si un lien expire, recréez-le dans SharePoint et remplacez le secret correspondant.
Lancer une actualisation à la main : onglet **Actions › Actualisation du dashboard › Run workflow**.

En local (Mac, fichiers OneDrive synchronisés) : `python3 build_dashboard.py` puis ouvrir `Palomano_Dashboard.html`.
