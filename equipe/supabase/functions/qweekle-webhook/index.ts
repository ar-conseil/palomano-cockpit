// PALOMANO — réception des webhooks Qweekle (fonction Supabase « qweekle-webhook »).
// Qweekle appelle https://<projet>.supabase.co/functions/v1/qweekle-webhook?k=<clé> à chaque
// réservation créée / modifiée / supprimée. La clé est vérifiée par qweekle_event() (schema_v12.sql),
// qui crée ou met à jour l'anniversaire / le centre / l'école. Déployée sans vérification JWT
// (Qweekle n'envoie pas de jeton Supabase) : c'est la clé de l'adresse qui protège.
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Palomano · webhook Qweekle", { status: 200 });
  const k = new URL(req.url).searchParams.get("k") ?? "";
  let p: unknown;
  try {
    p = await req.json();
  } catch {
    return new Response("JSON invalide", { status: 400 });
  }
  const url = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const r = await fetch(`${url}/rest/v1/rpc/qweekle_event`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ k, p }),
  });
  const t = await r.text();
  if (!r.ok) return new Response(/invalide/.test(t) ? "clé invalide" : "erreur", { status: /invalide/.test(t) ? 401 : 500 });
  return new Response(t, { status: 200, headers: { "Content-Type": "application/json" } });
});
