import { assertEquals } from "jsr:@std/assert@1";
import { priceFor } from "./ai.ts";

const table: Record<string, [number, number]> = { "gpt-5": [1.25, 10], "gpt-5-mini": [0.25, 2] };

Deno.test("the requested alias wins, then the dated snapshot falls back to its alias", () => {
  assertEquals(priceFor(table, "gpt-5-mini", "gpt-5-mini-2025-08-07"), [0.25, 2]);
  assertEquals(priceFor(table, "unknown", "gpt-5-mini-2025-08-07"), [0.25, 2]);
  assertEquals(priceFor(table, "unknown", "gpt-5-2025-08-07"), [1.25, 10], "longest prefix, not gpt-5 for gpt-5-mini");
  assertEquals(priceFor(table, "unknown", "gpt-5-mini-2025-08-07"), [0.25, 2]);
  assertEquals(priceFor(table, "o3", "o3-2025-04-16"), undefined);
});
