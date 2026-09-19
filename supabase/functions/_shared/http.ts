// Small HTTP helpers shared by every function.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, idempotency-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders, ...extra },
  });
}

export function error(status: number, code: string, detail?: string, extra?: Record<string, unknown>) {
  return json({ error: code, ...(detail ? { detail } : {}), ...(extra ?? {}) }, status);
}

/** Handles the CORS preflight; returns null for anything else. */
export function preflight(req: Request): Response | null {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return error(405, "method_not_allowed");
  return null;
}

/** Parses a JSON body, capping its size so a client can't post a novel. */
export async function readJson<T>(req: Request, maxBytes = 1_000_000): Promise<T | null> {
  const length = Number(req.headers.get("content-length") ?? "0");
  if (length > maxBytes) return null;
  try {
    const text = await req.text();
    if (text.length > maxBytes) return null;
    return JSON.parse(text) as T;
  } catch {
    return null;
  }
}

export function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing env ${name}`);
  return value;
}
