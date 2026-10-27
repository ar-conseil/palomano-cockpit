#!/usr/bin/env python3
"""
Chiffre Palomano_Dashboard.html (AES-256-GCM, clé dérivée du mot de passe par PBKDF2-SHA256)
et produit site/index.html : une page de connexion qui déchiffre le dashboard dans le navigateur.
Rien de lisible n'est publié sans le mot de passe.

Variable d'environnement : DASH_PASSWORD
Usage :  DASH_PASSWORD=... python3 encrypt_page.py
"""
import base64
import json
import os
import re
import sys
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

HERE = Path(__file__).resolve().parent
SRC = HERE / "Palomano_Dashboard.html"
SITE = HERE / "site"
ITERATIONS = 600_000

SHELL = """<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Palomano Cockpit</title>
<style>
:root{color-scheme:light;--bg:#f6f5f1;--card:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--ring:rgba(11,11,11,.12);--accent:#2a78d6;--bad:#b42323}
@media (prefers-color-scheme:dark){:root{color-scheme:dark;--bg:#0d0d0d;--card:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--ring:rgba(255,255,255,.12);--accent:#3987e5;--bad:#e66767}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--ink);font:15px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif;padding:16px}
form{background:var(--card);border:1px solid var(--ring);border-radius:16px;padding:28px;width:100%;max-width:360px;display:flex;flex-direction:column;gap:14px}
.logo{width:42px;height:42px;border-radius:11px;background:var(--accent);color:#fff;display:grid;place-items:center;font-weight:700}
h1{font-size:18px;margin:0}
p{margin:0;color:var(--ink2);font-size:13px}
input[type=password]{font:inherit;color:inherit;background:var(--bg);border:1px solid var(--ring);border-radius:9px;padding:10px 12px}
input:focus,button:focus{outline:2px solid var(--accent);outline-offset:1px}
label.rem{display:flex;gap:8px;align-items:center;font-size:13px;color:var(--ink2)}
button{font:inherit;font-weight:600;border:0;border-radius:9px;padding:10px;background:var(--accent);color:#fff;cursor:pointer}
#err{color:var(--bad);font-size:13px;min-height:1em}
</style>
</head>
<body>
<form id="f" autocomplete="on">
  <div class="logo">PL</div>
  <h1>Palomano Cockpit</h1>
  <p>Tableau de bord de pilotage · accès réservé à l'équipe Palomano Lille.</p>
  <input type="text" name="username" value="palomano" autocomplete="username" hidden>
  <input type="password" id="pw" placeholder="Mot de passe" autocomplete="current-password" required>
  <label class="rem"><input type="checkbox" id="rem" checked> Rester connecté sur cet appareil</label>
  <button type="submit" id="go">Ouvrir le dashboard</button>
  <div id="err" role="alert"></div>
</form>
<script>
(()=>{
const P=__PAYLOAD__;
const b64=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
async function keyFrom(pw){
  const base=await crypto.subtle.importKey("raw",new TextEncoder().encode(pw),"PBKDF2",false,["deriveKey"]);
  return crypto.subtle.deriveKey({name:"PBKDF2",salt:b64(P.salt),iterations:P.iter,hash:"SHA-256"},base,{name:"AES-GCM",length:256},true,["decrypt"]);
}
async function open(key){
  const pt=await crypto.subtle.decrypt({name:"AES-GCM",iv:b64(P.iv)},key,b64(P.ct));
  const html=new TextDecoder().decode(pt);
  document.open();document.write(html);document.close();
}
async function tryStored(){
  try{const raw=localStorage.getItem("palo.key."+P.salt);if(!raw)return false;
    const key=await crypto.subtle.importKey("raw",b64(raw),{name:"AES-GCM"},true,["decrypt"]);
    await open(key);return true}catch(e){try{localStorage.removeItem("palo.key."+P.salt)}catch(_){}return false}
}
document.getElementById("f").addEventListener("submit",async e=>{
  e.preventDefault();const err=document.getElementById("err"),go=document.getElementById("go");
  err.textContent="";go.disabled=true;go.textContent="Ouverture…";
  try{const key=await keyFrom(document.getElementById("pw").value);
    if(document.getElementById("rem").checked){try{const raw=new Uint8Array(await crypto.subtle.exportKey("raw",key));
      localStorage.setItem("palo.key."+P.salt,btoa(String.fromCharCode(...raw)))}catch(_){}}
    await open(key);
  }catch(x){err.textContent="Mot de passe incorrect.";go.disabled=false;go.textContent="Ouvrir le dashboard"}
});
if(document.readyState==="complete")tryStored();else addEventListener("load",tryStored);
})();
</script>
</body>
</html>
"""


def main():
    pw = os.environ.get("DASH_PASSWORD")
    if not pw:
        sys.exit("Variable d'environnement DASH_PASSWORD manquante")
    html = SRC.read_text(encoding="utf-8")
    # Sel fixe (public, propre à ce site) : « rester connecté » survit aux mises à jour ;
    # changer DASH_SALT_VERSION déconnecte tous les appareils.
    digest = hashes.Hash(hashes.SHA256())
    digest.update(f"palomano-cockpit-{os.environ.get('DASH_SALT_VERSION', '1')}".encode())
    salt = digest.finalize()[:16]
    key = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=ITERATIONS).derive(pw.encode())
    iv = os.urandom(12)
    ct = AESGCM(key).encrypt(iv, html.encode("utf-8"), None)
    payload = {"salt": base64.b64encode(salt).decode(), "iv": base64.b64encode(iv).decode(),
               "iter": ITERATIONS, "ct": base64.b64encode(ct).decode()}
    SITE.mkdir(exist_ok=True)
    (SITE / "index.html").write_text(SHELL.replace("__PAYLOAD__", json.dumps(payload)), encoding="utf-8")
    m = re.search(r'"generatedAt":"([^"]+)"', html)
    (SITE / "version.json").write_text(json.dumps({"generatedAt": m.group(1) if m else None}), encoding="utf-8")
    (SITE / ".nojekyll").write_text("")
    print(f"OK → {SITE / 'index.html'} (chiffré, {len(ct):,} octets)")


if __name__ == "__main__":
    main()
