// The one place the OpenAI key is used. Functions pass messages; this
// makes the call, bounds it in wall-clock time, and reports what it
// billed — the app's `CrosswordReviewService` and `FeatureCluesService`
// did all of this client-side with the user's own key.

import { env } from "./http.ts";

export type ChatUsage = {
  prompt_tokens: number;
  completion_tokens: number;
  reasoning_tokens: number;
};

export type ChatResult =
  | { ok: true; content: string; usage: ChatUsage; model: string }
  | { ok: false; status: number; message: string };

export type ChatOptions = {
  model: string;
  messages: { role: "system" | "user"; content: string }[];
  /** For reasoning models; omitted otherwise. */
  reasoningEffort?: "minimal" | "low" | "medium" | "high";
  /** Cap on completion tokens — the output limit the checklist asks for. */
  maxOutputTokens: number;
  timeoutMs: number;
};

export async function chat(options: ChatOptions): Promise<ChatResult> {
  const body: Record<string, unknown> = {
    model: options.model,
    messages: options.messages,
    response_format: { type: "json_object" },
    max_completion_tokens: options.maxOutputTokens,
  };
  if (options.reasoningEffort) body.reasoning_effort = options.reasoningEffort;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs);
  try {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${env("OPENAI_API_KEY")}`,
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    const text = await response.text();
    if (!response.ok) {
      // OpenAI's error body says why and masks the key; safe to log, but
      // the client only ever sees a generic code.
      let message = `HTTP ${response.status}`;
      try {
        const parsed = JSON.parse(text);
        if (parsed?.error?.message) message += `: ${parsed.error.message}`;
      } catch { /* not JSON */ }
      return { ok: false, status: response.status, message };
    }
    const parsed = JSON.parse(text);
    const content = parsed?.choices?.[0]?.message?.content;
    if (typeof content !== "string") {
      return { ok: false, status: 502, message: "no message content in the response" };
    }
    const usage = parsed?.usage ?? {};
    return {
      ok: true,
      content,
      model: typeof parsed?.model === "string" ? parsed.model : options.model,
      usage: {
        prompt_tokens: Number(usage.prompt_tokens ?? 0),
        completion_tokens: Number(usage.completion_tokens ?? 0),
        reasoning_tokens: Number(usage.completion_tokens_details?.reasoning_tokens ?? 0),
      },
    };
  } catch (e) {
    const aborted = e instanceof DOMException && e.name === "AbortError";
    return { ok: false, status: aborted ? 504 : 502, message: aborted ? "timed out" : String(e) };
  } finally {
    clearTimeout(timer);
  }
}

/** Cost in micro-dollars from a `[input, output]` per-million price pair. */
export function costMicros(usage: ChatUsage, price: [number, number] | undefined): number {
  if (!price) return 0;
  const dollars = (usage.prompt_tokens / 1e6) * price[0] + (usage.completion_tokens / 1e6) * price[1];
  return Math.round(dollars * 1_000_000);
}
