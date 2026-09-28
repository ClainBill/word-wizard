// The request lifecycle every AI function shares: who is asking, has the
// key been seen before, are they within quota, call the model, record what
// it cost. The rules themselves live in Postgres (`ai_reserve` and
// friends), so limits, models and the kill switch change without a deploy.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { callerOf } from "./supabase.ts";
import { serviceClient } from "./supabase.ts";
import { error, json, readJson } from "./http.ts";
import { chat, costMicros, type ChatOptions, type ChatUsage } from "./openai.ts";

export type AiKind = "crossword_review" | "feature_clues";

type Reservation = {
  allowed: boolean;
  reason?: string;
  cached?: boolean;
  request_id?: string;
  model?: string;
  premium?: boolean;
  remaining?: number;
  limit?: number;
  resets_at?: string;
  response?: { content: string };
  usage?: ChatUsage;
};

/**
 * What a function hands over: validated input plus how to turn it into a
 * model call. `idempotencyKey` is the client's key for *this* piece of work
 * (a puzzle id, a word id) — the same key again returns the same answer.
 */
export type AiJob<I> = {
  kind: AiKind;
  parse: (body: unknown) => I | null;
  idempotencyKey: (input: I) => string;
  /**
   * Which allowance within the kind this spends, when the kind's limit is
   * split (the crossword editor's is per puzzle size). Omitted, or an
   * empty string, means the kind's whole allowance.
   */
  bucket?: (input: I) => string;
  build: (input: I, model: string) => Omit<ChatOptions, "model">;
};

const priceCache: { at: number; prices: Record<string, [number, number]> } = { at: 0, prices: {} };

async function prices(db: SupabaseClient): Promise<Record<string, [number, number]>> {
  if (Date.now() - priceCache.at < 60_000) return priceCache.prices;
  const { data } = await db.from("app_config").select("value").eq("key", "ai_prices").single();
  priceCache.prices = (data?.value ?? {}) as Record<string, [number, number]>;
  priceCache.at = Date.now();
  return priceCache.prices;
}

/**
 * The price for what was actually run. OpenAI answers with the dated
 * snapshot ("gpt-5-mini-2025-08-07") of the alias we asked for
 * ("gpt-5-mini"); the table is keyed by alias, so try the request's
 * model, then the exact answer, then the longest alias the answer starts
 * with.
 */
export function priceFor(
  table: Record<string, [number, number]>,
  requested: string,
  answered: string,
): [number, number] | undefined {
  if (table[requested]) return table[requested];
  if (table[answered]) return table[answered];
  const aliases = Object.keys(table).filter((k) => answered.startsWith(k)).sort((a, b) => b.length - a.length);
  return aliases.length ? table[aliases[0]] : undefined;
}

export async function runAiJob<I>(req: Request, job: AiJob<I>): Promise<Response> {
  const user = await callerOf(req);
  if (!user) return error(401, "unauthenticated");

  const body = await readJson<unknown>(req, 200_000);
  const input = body == null ? null : job.parse(body);
  if (input == null) return error(400, "invalid_request");

  const db = serviceClient();
  const key = job.idempotencyKey(input);
  const { data, error: rpcError } = await db.rpc("ai_reserve", {
    p_user_id: user.id,
    p_kind: job.kind,
    p_key: key,
    p_bucket: job.bucket?.(input) ?? "",
  });
  if (rpcError) {
    console.error("ai_reserve", rpcError);
    return error(500, "reservation_failed");
  }
  const reservation = data as Reservation;

  if (!reservation.allowed) {
    switch (reservation.reason) {
      case "quota_exceeded":
        return error(402, "quota_exceeded", undefined, {
          limit: reservation.limit,
          premium: reservation.premium,
          resets_at: reservation.resets_at,
        });
      case "in_progress":
        return error(409, "in_progress");
      case "ai_disabled":
      case "global_cap":
        return error(503, "ai_unavailable", undefined, { reason: reservation.reason });
      default:
        return error(403, reservation.reason ?? "refused");
    }
  }

  if (reservation.cached) {
    return json({
      content: reservation.response?.content ?? "",
      model: reservation.model,
      usage: reservation.usage,
      cached: true,
    });
  }

  const model = reservation.model!;
  const result = await chat({ model, ...job.build(input, model) });
  if (!result.ok) {
    console.error(`${job.kind} ${model}: ${result.message}`);
    await db.rpc("ai_fail", { p_request_id: reservation.request_id, p_error: result.message });
    // 429 from the provider is a rate limit worth surfacing as such; the
    // rest is "not now", and the app keeps its deterministic content.
    return error(result.status === 429 ? 429 : 503, "provider_unavailable");
  }
  if (result.content.trim() === "") {
    // A reasoning model that spent its whole output budget thinking
    // answers with nothing. That is a failure, not an answer: it must not
    // be cached for the key, and the user must not pay for it.
    console.error(`${job.kind} ${model}: empty content (${result.usage.reasoning_tokens} reasoning tokens)`);
    await db.rpc("ai_fail", { p_request_id: reservation.request_id, p_error: "empty content" });
    return error(503, "provider_unavailable");
  }

  const cost = costMicros(result.usage, priceFor(await prices(db), model, result.model));
  await db.rpc("ai_complete", {
    p_request_id: reservation.request_id,
    p_response: { content: result.content },
    p_prompt_tokens: result.usage.prompt_tokens,
    p_completion_tokens: result.usage.completion_tokens,
    p_reasoning_tokens: result.usage.reasoning_tokens,
    p_cost_micros: cost,
  });

  return json({
    content: result.content,
    model: result.model,
    usage: result.usage,
    cached: false,
    remaining: reservation.remaining,
  });
}
