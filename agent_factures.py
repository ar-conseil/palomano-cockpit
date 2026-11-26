#!/usr/bin/env python3
"""
Agent factures — lit les factures reçues en pièce jointe sur la boîte de la direction (lille@palomano.com)
et les enregistre dans la comptabilité du dashboard (Supabase, schema_v38).

Pour chaque nouvel e-mail de la boîte de réception qui porte une pièce jointe PDF ou photo et qui parle
de facture / reçu / avoir :
  1. la pièce est lue par Claude, qui relève fournisseur, n°, date, HT / TVA / TTC par taux, et propose
     le compte comptable d'après le plan de comptes et l'historique des fournisseurs ;
  2. le fichier est rangé dans le stockage « factures » (dossier compta/AAAA-MM/) ;
  3. si la charge est déjà au grand livre (même montant, date proche), la pièce y est seulement rattachée ;
     sinon une écriture est créée — « OK » si la lecture est sûre, sinon « À vérifier ».
Rien n'est envoyé, payé ni supprimé : l'agent lit et enregistre.

Variables d'environnement :
  ANTHROPIC_API_KEY                   clé de l'API Claude (secret GitHub)
  SUPABASE_URL, SUPABASE_SERVICE_KEY  base de l'espace équipe
  MS_REFRESH_TOKEN, MS_TOKEN_DIR, DASH_PASSWORD   connexion Microsoft (voir fetch_sharepoint.py)
  AGENT_DEPUIS                        première date lue (défaut 2026-11-01)
  AGENT_MAX_PIECES                    pièces lues au plus par passage (défaut 40)
"""
import base64
import datetime as dt
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

import fetch_sharepoint as ms

SB_URL, SB_KEY = os.environ.get("SUPABASE_URL", "").rstrip("/"), os.environ.get("SUPABASE_SERVICE_KEY", "")
DEPUIS = os.environ.get("AGENT_DEPUIS", "2026-11-01")
MAX_PIECES = int(os.environ.get("AGENT_MAX_PIECES", "40"))
MODEL = os.environ.get("AGENT_MODEL", "claude-opus-5-5")
MAIL_SCOPE = "https://graph.microsoft.com/Mail.Read offline_access"
MOTS = re.compile(r"factur|invoice|avoir|re[çc]u|receipt|note d.honoraires|[ée]ch[ée]ance|relev[ée] de frais|\bFAC|\bINV|ticket", re.I)
EXT_OK = {"application/pdf": "pdf", "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}


# ───────────── Supabase ─────────────
def sb(path, body=None, method="GET", prefer="return=minimal", headers=None):
    h = {"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}", "Content-Type": "application/json", "Prefer": prefer}
    h.update(headers or {})
    req = urllib.request.Request(f"{SB_URL}/rest/v1/{path}", method=method, headers=h,
                                 data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def sb_all(path):
    out, i = [], 0
    while True:
        part = sb(path, prefer="", headers={"Range-Unit": "items", "Range": f"{i}-{i + 999}"})
        out += part
        if len(part) < 1000:
            return out
        i += 1000


def upload(path, data, ctype):
    req = urllib.request.Request(f"{SB_URL}/storage/v1/object/factures/{urllib.parse.quote(path)}", data=data, method="POST",
                                 headers={"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}", "Content-Type": ctype, "x-upsert": "true"})
    urllib.request.urlopen(req, timeout=120).read()


def state(ok, msg):
    sb("sync_state?on_conflict=key", [{"key": "agent_factures", "ok": ok, "message": msg[:500],
                                       "synced_at": dt.datetime.now(dt.timezone.utc).isoformat()}],
       "POST", "resolution=merge-duplicates,return=minimal")


# ───────────── Microsoft Graph (boîte de la direction, lecture seule) ─────────────
def mail_token():
    ms.SCOPE = MAIL_SCOPE   # même session Microsoft que les autres scripts, droit de lecture des e-mails
    err = "aucun jeton Microsoft"
    for rt in (ms.load_cached(), os.environ.get("MS_REFRESH_TOKEN")):
        if not rt:
            continue
        tok, err = ms.redeem(rt)
        if tok:
            if tok.get("refresh_token"):
                ms.save_cached(tok["refresh_token"])
            return tok["access_token"], None
    return None, err


def graph(url, tok):
    req = urllib.request.Request(url if url.startswith("http") else "https://graph.microsoft.com/v1.0" + url,
                                 headers={"Authorization": f"Bearer {tok}", "Prefer": 'outlook.body-content-type="text"'})
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.load(r)


# ───────────── Lecture d'une pièce par Claude ─────────────
SCHEMA = {
    "type": "object", "additionalProperties": False,
    "required": ["est_facture", "type_piece", "fournisseur", "numero", "date_piece", "date_comptable", "lignes",
                 "total_ht", "total_tva", "total_ttc", "deja_payee", "libelle", "compte", "confiance", "remarque"],
    "properties": {
        "est_facture": {"type": "boolean"},
        "type_piece": {"type": "string", "enum": ["facture", "avoir", "recu", "releve", "autre"]},
        "fournisseur": {"type": "string"},
        "numero": {"type": "string"},
        "date_piece": {"type": "string", "description": "AAAA-MM-JJ, vide si inconnue"},
        "date_comptable": {"type": "string", "description": "AAAA-MM-JJ"},
        "lignes": {"type": "array", "items": {"type": "object", "additionalProperties": False, "required": ["taux", "ht", "tva"],
                                               "properties": {"taux": {"type": "number"}, "ht": {"type": "number"}, "tva": {"type": "number"}}}},
        "total_ht": {"type": "number"}, "total_tva": {"type": "number"}, "total_ttc": {"type": "number"},
        "deja_payee": {"type": "boolean"},
        "libelle": {"type": "string"},
        "compte": {"type": "string"},
        "confiance": {"type": "string", "enum": ["haute", "moyenne", "basse"]},
        "remarque": {"type": "string"},
    },
}


def consignes(plan, histo):
    return f"""Tu tiens la comptabilité fournisseurs de PALOMANO LILLE (SAS, parc de loisirs intérieur pour enfants,
La Maillerie, Villeneuve-d'Ascq ; SIRET 932 630 783 ; TVA FR14932630783). On te donne une pièce reçue par e-mail.
Relève-la exactement comme un comptable, sans rien inventer.

- est_facture : vrai seulement pour une facture, un avoir ou un reçu adressé à Palomano Lille (pas un devis, une
  relance, une publicité, une convention, un bon de commande, un récapitulatif sans montant, ni une facture émise
  PAR Palomano à un client).
- fournisseur : nom court en majuscules comme dans l'historique ci-dessous quand c'est le même (ex. « Chaleur tournante »,
  « PRIMEO ENERGIE », « PALO FRANCHISE », « Pansard »).
- lignes : une ligne par taux de TVA (taux en décimal : 0.2, 0.1, 0.055, 0). Montants HT et TVA en euros.
  TVA non applicable (art. 293 B), autoliquidation ou intra-UE : taux 0, TVA 0. Pour un avoir, montants NÉGATIFS.
- date_comptable : date de la facture ; mais pour une facture mensuelle d'un service rendu le mois précédent
  (redevances, honoraires, ménage, community management, abonnement « octobre » facturé début novembre…),
  le dernier jour du mois concerné.
- compte : un numéro du plan de comptes ci-dessous. Suis l'historique du fournisseur quand il existe.
  Une facture qui regroupe plusieurs natures : le compte de la plus grosse.
- libelle : 3 à 8 mots (« Snacking », « Électricité novembre », « Redevance franchise octobre »…).
- confiance « haute » seulement si les montants sont lisibles et cohérents (HT + TVA = TTC) et le compte évident.
- remarque : ce qui mérite l'attention du dirigeant (impayé, échéance proche, montant inhabituel, illisible), sinon vide.

PLAN DE COMPTES (numéro — libellé) :
{plan}

HISTORIQUE (fournisseur → compte habituel, taux habituel) :
{histo}"""


def lire_piece(client, system, data, ctype, contexte):
    import anthropic
    bloc = ({"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": base64.b64encode(data).decode()}}
            if ctype == "application/pdf" else
            {"type": "image", "source": {"type": "base64", "media_type": ctype, "data": base64.b64encode(data).decode()}})
    resp = client.beta.messages.create(
        model=MODEL, max_tokens=16000,
        betas=["server-side-fallback-2026-07-01"], fallbacks="default",
        system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        output_config={"effort": "low", "format": {"type": "json_schema", "schema": SCHEMA}},
        messages=[{"role": "user", "content": [bloc, {"type": "text", "text": contexte}]}],
    )
    if resp.stop_reason == "refusal":
        raise RuntimeError("lecture refusée par le modèle")
    txt = next((b.text for b in resp.content if b.type == "text"), "")
    return json.loads(txt)


# ───────────── Agent ─────────────
def main():
    if not SB_URL or not SB_KEY:
        print("Agent factures : secrets Supabase absents, ignoré")
        return
    if not os.environ.get("ANTHROPIC_API_KEY"):
        state(False, "Clé de l'API Claude manquante (secret GitHub ANTHROPIC_API_KEY) : les factures ne sont pas lues")
        print("Agent factures : ANTHROPIC_API_KEY absent, ignoré")
        return
    try:
        sb("compta_pieces?select=id&limit=1", prefer="")
    except urllib.error.HTTPError:
        print("Agent factures : schema_v38 pas encore installé, ignoré")
        return
    tok, err = mail_token()
    if not tok:
        state(False, "Lecture des e-mails non autorisée par Microsoft (droit Mail.Read à accorder à l'application "
                     f"« Palomano Cockpit ») : {err}")
        print("Agent factures : pas d'accès aux e-mails —", err)
        return

    import anthropic
    client = anthropic.Anthropic()
    plan = sb_all("compta_plan?select=compte,libelle&order=compte")
    ecr = sb_all("compta_ecritures?select=id,date,compte,fournisseur,taux,ht,tva,sens,piece_id,source&date=gte.2026-01-01")
    vus = {m["message_id"] for m in sb_all("compta_mails?select=message_id")}
    connus = {p["empreinte"] for p in sb_all("compta_pieces?select=empreinte")}
    numeros = {(p["fournisseur"].lower(), p["numero"].strip()) for p in sb_all("compta_pieces?select=fournisseur,numero&numero=neq.")}

    comptes = {str(p["compte"]) for p in plan}
    histo = {}
    for e in ecr:
        if e["sens"] == "D" and e["fournisseur"]:
            histo.setdefault(e["fournisseur"], {}).setdefault((str(e["compte"]), e["taux"]), 0)
            histo[e["fournisseur"]][(str(e["compte"]), e["taux"])] += 1
    histo_txt = "\n".join(f"{f} → {max(c, key=c.get)[0]} ({max(c, key=c.get)[1]})" for f, c in sorted(histo.items()))
    system = consignes("\n".join(f"{p['compte']} — {p['libelle']}" for p in plan), histo_txt)

    since = DEPUIS + "T00:00:00Z"
    url = ("/me/mailFolders/inbox/messages?$top=50&$orderby=receivedDateTime asc"
           f"&$filter=receivedDateTime ge {since} and hasAttachments eq true"
           "&$select=id,subject,from,receivedDateTime,bodyPreview")
    n_mail = n_piece = n_ecr = n_lien = n_verif = 0
    alertes = []
    while url and n_piece < MAX_PIECES:
        page = graph(url.replace(" ", "%20"), tok)
        for m in page.get("value", []):
            if m["id"] in vus or n_piece >= MAX_PIECES:
                continue
            exp = ((m.get("from") or {}).get("emailAddress") or {}).get("address", "")
            sujet = m.get("subject") or ""
            atts = graph(f"/me/messages/{m['id']}/attachments?$select=id,name,contentType,size,isInline", tok).get("value", [])
            pj = [a for a in atts if a.get("@odata.type") == "#microsoft.graph.fileAttachment" and not a.get("isInline")
                  and (a.get("contentType") in EXT_OK or a.get("name", "").lower().endswith(".pdf"))
                  and (a.get("size") or 0) < 15e6 and not (a.get("contentType", "").startswith("image/") and (a.get("size") or 0) < 25e3)]
            pertinent = MOTS.search(sujet + " " + (m.get("bodyPreview") or "") + " " + " ".join(a.get("name", "") for a in pj))
            lues = 0
            for a in (pj if pertinent else []):
                full = graph(f"/me/messages/{m['id']}/attachments/{a['id']}", tok)
                data = base64.b64decode(full["contentBytes"])
                emp = hashlib.sha256(data).hexdigest()
                if emp in connus:
                    continue
                connus.add(emp)
                ctype = a.get("contentType") if a.get("contentType") in EXT_OK else "application/pdf"
                recu = m["receivedDateTime"]
                base = {"empreinte": emp, "source": "mail", "message_id": m["id"], "expediteur": exp, "sujet": sujet[:300],
                        "recu_le": recu, "nom_fichier": a.get("name", "")[:200]}
                try:
                    x = lire_piece(client, system, data, ctype,
                                   f"E-mail reçu le {recu[:10]} de {exp} — objet : « {sujet} » — fichier : {a.get('name', '')}")
                except Exception as e:
                    sb("compta_pieces", {**base, "statut": "erreur", "note": str(e)[:300]}, "POST")
                    alertes.append(f"{a.get('name', '')} : lecture impossible")
                    continue
                n_piece += 1
                lues += 1
                if not x["est_facture"]:
                    sb("compta_pieces", {**base, "est_facture": False, "statut": "ignoree", "extrait": x, "note": x.get("remarque", "")[:300]}, "POST")
                    continue
                four, num = x["fournisseur"].strip(), x["numero"].strip()
                mois = (x["date_comptable"] or recu[:10])[:7]
                path = f"compta/{mois}/{emp[:10]}-{re.sub(r'[^A-Za-z0-9._-]+', '_', a.get('name', 'facture'))[:80]}"
                if not path.lower().endswith("." + EXT_OK.get(ctype, "pdf")):
                    path += "." + EXT_OK.get(ctype, "pdf")
                upload(path, data, ctype)
                doublon = num and (four.lower(), num) in numeros
                piece = sb("compta_pieces", {**base, "fichier_path": path, "est_facture": True, "fournisseur": four, "numero": num,
                                             "date_piece": x["date_piece"] or None, "total_ttc": x["total_ttc"], "extrait": x,
                                             "statut": "doublon" if doublon else "traitee", "note": x.get("remarque", "")[:300]},
                           "POST", "return=representation")[0]
                if doublon:
                    continue
                numeros.add((four.lower(), num))
                if x.get("remarque"):
                    alertes.append(f"{four} : {x['remarque'][:120]}")
                # déjà au grand livre ? (même TTC à 2 centimes, date à ± 20 jours, sans pièce) → on rattache
                d0 = dt.date.fromisoformat(x["date_comptable"] or recu[:10])
                ttc = round(x["total_ttc"], 2)
                cand = [e for e in ecr if e["sens"] == "D" and not e.get("piece_id") and e["source"] != "ca"
                        and abs(dt.date.fromisoformat(e["date"]) - d0).days <= 20
                        and (abs(float(e["ht"]) + float(e["tva"] or 0) - ttc) < 0.03 or abs(float(e["ht"]) - x["total_ht"]) < 0.03)]
                if cand:
                    e = min(cand, key=lambda e: abs(dt.date.fromisoformat(e["date"]) - d0).days)
                    sb(f"compta_ecritures?id=eq.{e['id']}", {"piece_id": piece["id"]}, "PATCH")
                    e["piece_id"] = piece["id"]
                    n_lien += 1
                    continue
                compte = x["compte"] if x["compte"] in comptes else "606410"
                coherent = abs(round(sum(l["ht"] + l["tva"] for l in x["lignes"]), 2) - ttc) < 0.05
                statut = "ok" if x["confiance"] == "haute" and x["compte"] in comptes and coherent else "a_verifier"
                lignes = x["lignes"] or [{"taux": 0, "ht": x["total_ht"], "tva": x["total_tva"]}]
                rows = [{"date": d0.isoformat(), "compte": compte, "fournisseur": four, "libelle": x["libelle"][:120] or "Facture",
                         "taux": l["taux"], "sens": "D", "ht": round(l["ht"], 2), "tva": round(l["tva"], 2),
                         "commentaire": (f"Facture {num} - " if num else "") + f"reçue par e-mail le {recu[8:10]}/{recu[5:7]} de {exp} (agent)"
                                        + (" - déjà payée" if x["deja_payee"] else "") + (f" - {x['remarque'][:150]}" if x.get("remarque") else ""),
                         "statut": statut, "source": "facture", "piece_id": piece["id"]} for l in lignes if l["ht"] or l["tva"]]
                if rows:
                    sb("compta_ecritures", rows, "POST")
                    n_ecr += len(rows)
                    n_verif += statut != "ok"
            sb("compta_mails?on_conflict=message_id", [{"message_id": m["id"], "recu_le": m["receivedDateTime"], "expediteur": exp,
                                                       "sujet": sujet[:300], "pieces": lues}], "POST", "resolution=merge-duplicates,return=minimal")
            n_mail += 1
        url = page.get("@odata.nextLink")
    msg = (f"{n_mail} e-mail{'s' * (n_mail > 1)} examiné{'s' * (n_mail > 1)}, {n_piece} pièce{'s' * (n_piece > 1)} lue{'s' * (n_piece > 1)} : "
           f"{n_ecr} écriture{'s' * (n_ecr > 1)} créée{'s' * (n_ecr > 1)}" + (f" dont {n_verif} à vérifier" if n_verif else "")
           + f", {n_lien} rattachée{'s' * (n_lien > 1)} au grand livre" + (" · ⚠ " + " · ".join(alertes[:4]) if alertes else ""))
    state(True, msg if n_mail else "Aucun nouvel e-mail de facture")
    print("Agent factures :", msg)


if __name__ == "__main__":
    main()
