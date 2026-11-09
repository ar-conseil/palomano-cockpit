// PALOMANO — réception des webhooks Qweekle (fonction Supabase « qweekle-webhook »).
// Qweekle appelle .../functions/v1/qweekle-webhook?k=<clé> à chaque réservation créée / modifiée / supprimée
// et à chaque vente. 1) qweekle_event() (schema_v12.sql) vérifie la clé et crée / met à jour la réservation.
// 2) Pour un anniversaire (ou un paiement sur sa commande), la fonction lit aussitôt la commande dans le
//    back-office Qweekle avec le compte dédié (secrets QWEEKLE_EMAIL / QWEEKLE_PASSWORD) : options (dont
//    Animateur), total, acompte et reste à payer arrivent en quelques secondes. Même logique que sync_commandes.py,
//    qui repasse régulièrement en filet de sécurité (options ajoutées sans paiement, par exemple).
// Déployée sans vérification JWT : c'est la clé de l'adresse qui protège.

const SB = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const QW = (Deno.env.get("QWEEKLE_URL") ?? "https://palomano.qweekle.com").replace(/\/$/, "");
const QU = Deno.env.get("QWEEKLE_EMAIL") ?? "";
const QP = Deno.env.get("QWEEKLE_PASSWORD") ?? "";
const UA = "Mozilla/5.0 (PalomanoDashboard)";
const H = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" };

// deno-lint-ignore no-explicit-any
async function sb(path: string, init: RequestInit = {}): Promise<any> {
  const r = await fetch(`${SB}/rest/v1/${path}`, { ...init, headers: { ...H, ...(init.headers ?? {}) } });
  const t = await r.text();
  if (!r.ok) throw new Error(`supabase ${r.status} ${t.slice(0, 200)}`);
  return t ? JSON.parse(t) : null;
}

async function log(order: string, result: string) {
  try {
    await sb("qweekle_events", {
      method: "POST", headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ event_type: "commande", order_id: order, label: "", result }),
    });
  } catch (_) { /* le journal ne doit jamais bloquer */ }
}

// ───────────── Session du back-office Qweekle ─────────────
class Jar {
  c = new Map<string, string>();
  take(r: Response) {
    for (const sc of r.headers.getSetCookie()) {
      const kv = sc.split(";")[0];
      const i = kv.indexOf("=");
      if (i > 0) this.c.set(kv.slice(0, i).trim(), kv.slice(i + 1));
    }
  }
  get header() { return [...this.c].map(([k, v]) => `${k}=${v}`).join("; "); }
}

async function qget(jar: Jar, path: string, form?: Record<string, string>) {
  let url = path.startsWith("http") ? path : QW + path;
  let method = form ? "POST" : "GET";
  let body: string | undefined = form ? new URLSearchParams(form).toString() : undefined;
  for (let i = 0; i < 6; i++) {
    const headers: Record<string, string> = { Cookie: jar.header, "User-Agent": UA, "Accept-Language": "fr-FR,fr" };
    if (body) headers["Content-Type"] = "application/x-www-form-urlencoded";
    const r = await fetch(url, { method, headers, body, redirect: "manual" });
    jar.take(r);
    const loc = r.headers.get("location");
    if (r.status >= 300 && r.status < 400 && loc) {
      await r.body?.cancel();
      url = new URL(loc, url).href; method = "GET"; body = undefined;
      continue;
    }
    return { url, text: await r.text() };
  }
  throw new Error("trop de redirections Qweekle");
}

const unesc = (s: string) =>
  s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#0?39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ").replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCharCode(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(+d));
const text = (h: string) => unesc((h ?? "").replace(/<[^>]+>/g, " ")).replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();
const money = (s: string) => {
  const v = parseFloat((s ?? "").replace(/[\s\u00a0]/g, "").replace(/[^\d,.\-]/g, "").replace(",", "."));
  return Number.isFinite(v) ? Math.round(v * 100) / 100 : null;
};
const attr = (tag: string, name: string) => {
  const m = tag.match(new RegExp(`\\b${name}="([^"]*)"`));
  return m ? unesc(m[1]) : null;
};

async function login(jar: Jar) {
  const { text: page } = await qget(jar, "/login");
  const form: Record<string, string> = {};
  for (const tag of page.match(/<input\b[^>]*>/g) ?? []) {
    const n = attr(tag, "name");
    if (n) form[n] = attr(tag, "value") ?? "";
  }
  Object.assign(form, { username: QU, password: QP, login: "" });
  const { url } = await qget(jar, "/login", form);
  if (/\/login\/?$/.test(url)) throw new Error("connexion Qweekle refusée (compte dédié ?)");
}

// Fiche de la réservation (data-booking_url) dans la liste du jour de la fête
async function panelUrl(jar: Jar, day: string, bookingId: string) {
  const [y, m, d] = day.split("-");
  const fr = `${d}/${m}/${y}`;
  const q = new URLSearchParams({
    "filters[agendas__start_at]": "", "filters[agendas__from_at]": fr, "filters[agendas__to_at]": fr,
    "filters[activities__label]": "Anniversaire", "filters[agenda_bookings__expirated]": "0",
  });
  for (let page = 1; page < 6; page++) {
    q.set("page", String(page));
    const { url, text: html } = await qget(jar, `/planning/v2/bookings?${q}`);
    if (/\/login\/?$/.test(url)) throw new Error("session Qweekle perdue");
    const rows = (html.match(/<tr\b[\s\S]*?<\/tr>/g) ?? []).filter((r) => r.includes("data-booking_url"));
    if (!rows.length) break;
    const row = rows.find((r) => r.includes(`data-booking_id="${bookingId}"`)) ??
      rows.find((r) => r.includes(bookingId));
    const m = row?.match(/data-booking_url="([^"]+)"/);
    if (m) return unesc(m[1]);
  }
  return null;
}

type Line = { q: number; p: string; m: number | null; formule: boolean };
const FORMULE = /^(palo-?fiesta|anniversaire\b)/i;

function parsePanel(h: string) {
  const out = { commande: "", lignes: [] as Line[], total: null as number | null, encaisse: null as number | null,
                reste: null as number | null };
  out.commande = (text(h).match(/Commande N°\s*([A-Z]-[\d-]+)/) ?? [])[1] ?? "";
  let last: Line | null = null;
  for (const tb of h.match(/<table\b[\s\S]*?<\/table>/g) ?? []) {
    for (const tr of tb.match(/<tr\b[\s\S]*?<\/tr>/g) ?? []) {
      const cells = [...tr.matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/g)].map((c) => text(c[1]));
      if (cells.length >= 3 && /^\d+$/.test(cells[0])) {
        last = { q: +cells[0], p: cells[1], m: money(cells[2]), formule: FORMULE.test(cells[1]) };
        out.lignes.push(last);
        continue;
      }
      const joined = cells.join(" ");
      if (cells.length <= 2 && / - \d\d\/\d\d\/\d{4} \d\d:\d\d/.test(joined) && !/^\d\d\/\d\d\/\d{4} [A-Z]-/.test(joined)) {
        if (last) last.formule = true;            // produit qui porte les créneaux réservés = la formule
        continue;
      }
      if (cells.length === 2) {
        const lab = cells[0].toLowerCase();
        if (lab.startsWith("total de la commande")) out.total = money(cells[1]);
        else if (lab.startsWith("paiements encaiss")) out.encaisse = money(cells[1]);
        else if (lab === "solde" || lab.startsWith("paiements attendus")) out.reste = money(cells[1]);
      }
    }
  }
  if (out.total !== null) {
    out.encaisse = out.encaisse ?? 0;
    if (out.reste === null) out.reste = Math.round((out.total - out.encaisse) * 100) / 100;
  }
  return out;
}

// ───────────── Lecture de la commande d'un anniversaire ─────────────
async function refreshOrder(order: string, bookingId?: string) {
  if (!QU || !QP) return log(order, "commande non lue : compte Qweekle dédié non configuré (secrets de la fonction)");
  try {
    const rows = await sb(`anniversaires?qweekle_order=eq.${encodeURIComponent(order)}&statut=neq.annule` +
      "&select=id,date,qweekle_booking,option_animateur,commande,paiement&order=id&limit=1");
    if (!rows?.length) return log(order, "commande non lue : anniversaire introuvable");
    const a = rows[0];
    const bid = bookingId || a.qweekle_booking;
    if (!bid) return log(order, "commande non lue : n° de réservation inconnu (lue au prochain passage)");
    const jar = new Jar();
    await login(jar);
    const url = await panelUrl(jar, a.date, bid);
    if (!url) return log(order, "commande non lue : fiche introuvable dans Qweekle");
    const o = parsePanel((await qget(jar, url)).text);
    if (o.total === null && !o.lignes.length) return log(order, "commande non lue : fiche illisible (format Qweekle modifié ?)");
    const opts = o.lignes.filter((l) => !l.formule).map((l) => ({ q: l.q, p: l.p }));
    const anim = opts.some((l) => /animat/i.test(l.p));
    const pay = o.total === null ? null : o.total > 0 && (o.reste ?? 0) <= 0.009 ? "paye" : (o.encaisse ?? 0) > 0 ? "acompte" : "non_paye";
    const now = new Date().toISOString();
    const patch: Record<string, unknown> = { commande: opts, commande_sync_at: now, updated_at: now };
    if (anim && !a.option_animateur) patch.option_animateur = true;   // jamais décochée
    if (pay) patch.paiement = pay;
    await sb(`anniversaires?id=eq.${a.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify(patch) });
    await sb("anniversaires_paiement?on_conflict=anniversaire_id", {
      method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify([{ anniversaire_id: a.id, commande: o.commande, total: o.total, encaisse: o.encaisse,
                              reste: o.reste, lignes: o.lignes.map(({ q, p, m }) => ({ q, p, m })), synced_at: now }]),
    });
    await log(order, `commande lue : ${opts.length} option(s)${anim ? " dont Animateur" : ""}` +
      (o.total !== null ? `, total ${o.total} €, reste ${o.reste} €` : ""));
  } catch (e) {
    await log(order, "erreur commande : " + (e instanceof Error ? e.message : String(e)));
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Palomano · webhook Qweekle", { status: 200 });
  const k = new URL(req.url).searchParams.get("k") ?? "";
  // deno-lint-ignore no-explicit-any
  let p: any;
  try {
    p = await req.json();
  } catch {
    return new Response("JSON invalide", { status: 400 });
  }
  const r = await fetch(`${SB}/rest/v1/rpc/qweekle_event`, { method: "POST", headers: H, body: JSON.stringify({ k, p }) });
  const t = await r.text();
  if (!r.ok) return new Response(/invalide/.test(t) ? "clé invalide" : "erreur", { status: /invalide/.test(t) ? 401 : 500 });

  // Clé valide : lecture de la commande en arrière-plan (Qweekle reçoit sa réponse tout de suite)
  const et = String(p?.event_type ?? "");
  const label = String(p?.label ?? "").toLowerCase();
  let job: Promise<unknown> | null = null;
  if (/^booking\.(created|updated)$/.test(et) && label.startsWith("anniversaire") && p?.order_id) {
    job = sb(`anniversaires?qweekle_order=eq.${encodeURIComponent(p.order_id)}`, {
      method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ qweekle_booking: p.id }),
    }).catch(() => null).then(() => refreshOrder(p.order_id, p.id));
  } else if (et === "sale.created" && p?.origin_order_id) {
    job = refreshOrder(p.origin_order_id);    // paiement (acompte, solde) sur une commande
  }
  // deno-lint-ignore no-explicit-any
  if (job) (globalThis as any).EdgeRuntime?.waitUntil ? (globalThis as any).EdgeRuntime.waitUntil(job) : await job;
  return new Response(t, { status: 200, headers: { "Content-Type": "application/json" } });
});
