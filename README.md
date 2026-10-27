# Palomano Cockpit

Tableau de bord de pilotage de Palomano Lille (parc La Maillerie).

Toutes les 30 minutes, GitHub Actions :
1. télécharge les 3 fichiers du dossier SharePoint `PARC/SUIVI PARC` avec le compte Microsoft de la direction, en lecture seule (`fetch_sharepoint.py`) ;
2. génère le dashboard (`build_dashboard.py` + `template.html`) ;
3. le chiffre avec le mot de passe de l'équipe (`encrypt_page.py`, AES-256-GCM) et le publie sur GitHub Pages.

Aucune donnée n'est stockée dans ce dépôt : seule la page chiffrée est publiée.

Secrets du dépôt : `MS_REFRESH_TOKEN` (session Microsoft) et `DASH_PASSWORD`.
Si la session Microsoft expire (changement de mot de passe…), relancez sur le Mac : `python3 connect_microsoft.py`.
Lancer une actualisation à la main : onglet **Actions › Actualisation du dashboard › Run workflow**.

En local (Mac, fichiers OneDrive synchronisés) : `python3 build_dashboard.py` puis ouvrir `Palomano_Dashboard.html`.
