// POST /ai-crossword-review   { puzzle_id, rendered, word_count }
//   → 200 { content: '<verdict JSON>', model, usage, cached, remaining }
//   → 401 | 400 | 402 quota_exceeded | 409 | 429 | 503
//
// Replaces the app's direct OpenAI call in `CrosswordReviewService`. The
// client sends the puzzle as the reviewer sees it — `renderForReview` in
// editorial.dart, answers, clues, ids and frequencies: data, not
// instructions — and the server supplies the editor's brief, the model,
// the reasoning effort and the output cap. The verdict comes back as the
// model's JSON string; the app parses and *verifies* it exactly as before
// (§9.4), so a bad rewrite is discarded there, not trusted here.

import { preflight } from "../_shared/http.ts";
import { runAiJob } from "../_shared/ai.ts";
import { crosswordReviewSystemPrompt } from "../_shared/prompts.ts";

type Input = { puzzleId: string; rendered: string; wordCount: number };

Deno.serve((req) =>
  preflight(req) ??
  runAiJob<Input>(req, {
    kind: "crossword_review",
    parse: (body) => {
      const b = body as Record<string, unknown>;
      const puzzleId = typeof b.puzzle_id === "string" ? b.puzzle_id.trim() : "";
      const rendered = typeof b.rendered === "string" ? b.rendered : "";
      const wordCount = Number(b.word_count ?? 0);
      if (!puzzleId || puzzleId.length > 120) return null;
      if (!rendered || rendered.length > 60_000) return null;
      if (!Number.isInteger(wordCount) || wordCount < 1 || wordCount > 200) return null;
      return { puzzleId, rendered, wordCount };
    },
    // One review per puzzle: a retry after a lost response is free, and a
    // second "review" tap can't bill twice.
    idempotencyKey: (i) => i.puzzleId,
    build: (i) => ({
      messages: [
        { role: "system", content: crosswordReviewSystemPrompt },
        { role: "user", content: i.rendered },
      ],
      reasoningEffort: "low",
      // Roughly 40 tokens a clue for the edits, plus notes; reasoning
      // tokens count against this too, hence the floor.
      maxOutputTokens: Math.min(16_000, 4_000 + 60 * i.wordCount),
      // The app's own deadline was 45 s + 1.5 s a word; capped under the
      // Edge Function wall-clock limit (150 s on the free plan, 400 s on
      // Pro — raise the cap once on Pro). A Mega at `low` effort measured
      // ~25 s, so this is headroom, not the norm.
      timeoutMs: Math.min(140_000, 45_000 + 1_500 * i.wordCount),
    }),
  })
);
