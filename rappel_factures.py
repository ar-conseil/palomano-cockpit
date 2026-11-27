#!/usr/bin/env python3
"""
Rappel mensuel des factures manquantes — à partir du 3 de chaque mois, envoie à la direction (lille@palomano.com)
la liste des pièces qui manquent pour clôturer le mois précédent :
  · factures attendues : charges récurrentes provisionnées par Rodolph dont la facture n'est pas arrivée
    (loyer, assurance, honoraires, abonnements…) ;
  · dépenses sans facture : sorties du relevé CIC (compte ou carte) passées en comptabilité sans pièce jointe ;
  · sorties du relevé non classées.
Pour compléter : transférer l'e-mail du fournisseur (ou envoyer le PDF / la photo) à lille@palomano.com —
l'agent factures le lit au passage suivant et le rattache à la bonne ligne.
L'e-mail part une seule fois par mois ; la liste à jour reste visible dans le dashboard (état « factures_manquantes »).
Les salaires, cotisations sociales, frais bancaires et intérêts ne sont pas réclamés (justifiés par la paie et le relevé).
Variables : SUPABASE_URL, SUPABASE_SERVICE_KEY, connexion Microsoft (voir agent_factures.py).
Usage : python3 rappel_factures.py [--envoyer]   (--envoyer : force l'envoi même déjà fait ce mois-ci)
"""
import datetime as dt
import html
import json
import re
import sys
import urllib.error
import urllib.request

import agent_factures as af
import fetch_sharepoint as ms

DIRECTION = "lille@palomano.com"
SANS_PIECE = ("641", "645", "6278", "661", "681", "687")       # paie, charges sociales, banque, intérêts, amortissements
MOIS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]


def mois_prec(d):
    p = d.replace(day=1) - dt.timedelta(days=1)
    return p.strftime("%Y-%m")


def eur(v):
    return f"{v:,.2f} €".replace(",", " ").replace(".", ",")


def liste(mois):
    deb, fin = mois + "-01", (dt.date.fromisoformat(mois + "-01").replace(day=28) + dt.timedelta(days=4)).replace(day=1).isoformat()
    ecr = af.sb_all(f"compta_ecritures?select=id,date,compte,fournisseur,libelle,ht,tva,sens,statut,source,piece_id,facture_id,commentaire"
                    f"&date=gte.{deb}&date=lt.{fin}")
    attendues = [e for e in ecr if e["statut"] == "provisoire" and e["sens"] == "D"]
    sans = [e for e in ecr if e["sens"] == "D" and e["source"] in ("banque", "carte") and not e.get("piece_id") and not e.get("facture_id")
            and not str(e["compte"]).startswith(SANS_PIECE) and float(e["ht"]) + float(e["tva"] or 0) >= 5]
    try:
        bq = af.sb_all(f"compta_banque?select=date,libelle,montant,ecriture_id,ignore&date=gte.{deb}&date=lt.{fin}&montant=lt.0")
    except urllib.error.HTTPError:
        bq = []
    non_classees = [b for b in bq if not b.get("ecriture_id") and not b.get("ignore")
                    and not re.search(r"RELEVE CARTE|DIRECTION GENERALE|DGFIP|SALAIRE|URSSAF|ALPRO|INTERETS|FACT SGT", b["libelle"], re.I)]
    return attendues, sans, non_classees


def message(mois, attendues, sans, non_classees):
    nom = f"{MOIS[int(mois[5:]) - 1]} {mois[:4]}"
    n = len(attendues) + len(sans) + len(non_classees)
    li = lambda txt: f"<li style='margin:3px 0'>{txt}</li>"
    blocs = []
    if attendues:
        blocs.append("<h3 style='margin:18px 0 6px'>Factures attendues (pas encore reçues)</h3><ul>" + "".join(
            li(f"<b>{html.escape(e['fournisseur'])}</b> — {html.escape(e['libelle'] or '')} · environ {eur(float(e['ht']) + float(e['tva'] or 0))} TTC")
            for e in sorted(attendues, key=lambda e: -float(e["ht"]))) + "</ul>")
    if sans:
        blocs.append("<h3 style='margin:18px 0 6px'>Dépenses payées sans facture</h3><ul>" + "".join(
            li(f"{e['date'][8:10]}/{e['date'][5:7]} · <b>{html.escape(e['fournisseur'])}</b> — {html.escape(e['libelle'] or '')} · {eur(float(e['ht']) + float(e['tva'] or 0))} TTC")
            for e in sorted(sans, key=lambda e: e["date"])) + "</ul>")
    if non_classees:
        blocs.append("<h3 style='margin:18px 0 6px'>Sorties du relevé CIC à expliquer</h3><ul>" + "".join(
            li(f"{b['date'][8:10]}/{b['date'][5:7]} · {html.escape(b['libelle'][:90])} · {eur(-float(b['montant']))}")
            for b in sorted(non_classees, key=lambda b: b["date"])) + "</ul>")
    corps = (f"<div style='font-family:Arial,sans-serif;font-size:14px;color:#222;line-height:1.5'>"
             f"<p>Bonjour Antonin,</p><p>Pour clôturer <b>{nom}</b>, il manque <b>{n} pièce{'s' * (n > 1)}</b>.</p>" + "".join(blocs) +
             "<h3 style='margin:18px 0 6px'>Comment me les envoyer</h3>"
             "<p>Transférez simplement l'e-mail du fournisseur, ou envoyez le PDF ou une photo de la facture, à "
             f"<b>{DIRECTION}</b>. Je les lis au passage suivant (moins d'une heure) et je les range sur la bonne ligne.<br>"
             "Une facture d'animateur ou de prestataire peut aussi être déposée dans l'espace équipe › Facturation.<br>"
             "Une sortie sans facture (remboursement, virement interne…) : indiquez-le dans Comptabilité › Rapprochement bancaire.</p>"
             "<p style='color:#777;font-size:12px'>Rodolph, agent financier de Palomano Lille · message automatique, une fois par mois. "
             "Les salaires, cotisations sociales et frais bancaires ne sont pas réclamés.</p></div>")
    return f"Palomano — {n} facture{'s' * (n > 1)} manquante{'s' * (n > 1)} pour {nom}", corps, n


def envoyer(sujet, corps):
    tok, err = None, None
    ms.SCOPE = "https://graph.microsoft.com/Mail.Send offline_access"
    for rt in (ms.load_cached(), __import__("os").environ.get("MS_REFRESH_TOKEN")):
        if not rt:
            continue
        t, err = ms.redeem(rt)
        if t:
            if t.get("refresh_token"):
                ms.save_cached(t["refresh_token"])
            tok = t["access_token"]
            break
    if not tok:
        return f"e-mail non envoyé : droit Mail.Send à accorder à l'application « Palomano Cockpit » ({err})"
    body = {"message": {"subject": sujet, "body": {"contentType": "HTML", "content": corps},
                        "toRecipients": [{"emailAddress": {"address": DIRECTION}}]}, "saveToSentItems": True}
    req = urllib.request.Request("https://graph.microsoft.com/v1.0/me/sendMail", data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=60).read()
        return "e-mail envoyé à " + DIRECTION
    except urllib.error.HTTPError as e:
        return f"e-mail non envoyé (HTTP {e.code})"


def main():
    if not af.SB_URL or not af.SB_KEY:
        return print("Rappel factures : secrets Supabase absents, ignoré")
    today = dt.datetime.now(dt.timezone(dt.timedelta(hours=1))).date()
    mois = mois_prec(today)
    try:
        attendues, sans, non_classees = liste(mois)
    except urllib.error.HTTPError as e:
        return print(f"Rappel factures : comptabilité illisible ({e.code}), ignoré")
    sujet, corps, n = message(mois, attendues, sans, non_classees)
    deja = (af.sb("sync_state?key=eq.factures_manquantes_envoi&select=message", prefer="") or [{}])[0].get("message", "")
    statut = ""
    if n and (today.day >= 3 and deja != mois or "--envoyer" in sys.argv):
        statut = envoyer(sujet, corps)
        if statut.startswith("e-mail envoyé"):
            af.sb("sync_state?on_conflict=key", [{"key": "factures_manquantes_envoi", "ok": True, "message": mois,
                                                   "synced_at": dt.datetime.now(dt.timezone.utc).isoformat()}],
                  "POST", "resolution=merge-duplicates,return=minimal")
    elif deja == mois:
        statut = "e-mail du mois déjà envoyé"
    resume = (f"{MOIS[int(mois[5:]) - 1]} : {n} pièce(s) manquante(s) — {len(attendues)} facture(s) attendue(s), "
              f"{len(sans)} dépense(s) sans facture, {len(non_classees)} sortie(s) du relevé à expliquer"
              + (f" · {statut}" if statut else ""))
    af.sb("sync_state?on_conflict=key", [{"key": "factures_manquantes", "ok": not statut.startswith("e-mail non"), "message": resume[:1500],
                                           "synced_at": dt.datetime.now(dt.timezone.utc).isoformat()}], "POST", "resolution=merge-duplicates,return=minimal")
    print("Rappel factures :", resume)


if __name__ == "__main__":
    main()
