// POST /ai-feature-clues   { headword, pos, gloss, key? }
//   → 200 { content: '{"clues":[…]}', model, usage, cached, remaining }
//   → 401 | 400 | 402 quota_exceeded | 409 | 429 | 503
//
// Replaces the app's direct OpenAI call in `FeatureCluesService`: the
// client sends the word, the server holds the instructions and the key.

import { preflight } from "../_shared/http.ts";
import { runAiJob } from "../_shared/ai.ts";
import { featureCluesSystemPrompt } from "../_shared/prompts.ts";

type Input = { headword: string; pos: string; gloss: string; key: string };

function clean(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  return text.length === 0 || text.length > max ? null : text;
}

Deno.serve((req) =>
  preflight(req) ??
  runAiJob<Input>(req, {
    kind: "feature_clues",
    parse: (body) => {
      const b = body as Record<string, unknown>;
      const headword = clean(b.headword, 80);
      const pos = clean(b.pos, 40) ?? "";
      const gloss = clean(b.gloss, 1000);
      if (!headword || !gloss) return null;
      // The word itself is the natural key: the same word gets the same
      // clues, and a second tap in the same session costs nothing.
      const key = clean(b.key, 120) ?? `${headword.toLowerCase()}|${pos.toLowerCase()}`;
      return { headword, pos, gloss, key };
    },
    idempotencyKey: (i) => i.key,
    build: (i) => ({
      messages: [
        { role: "system", content: featureCluesSystemPrompt },
        { role: "user", content: `Word: ${i.headword}\nPart of speech: ${i.pos}\nDefinition: ${i.gloss}` },
      ],
      // A reasoning model: at the default effort gpt-5-mini used 300 tokens
      // thinking and had none left to answer, so "minimal" — this is three
      // short lines — and a cap with room for the thinking it still does.
      reasoningEffort: "minimal",
      maxOutputTokens: 1_500,
      timeoutMs: 20_000,
    }),
  })
);
