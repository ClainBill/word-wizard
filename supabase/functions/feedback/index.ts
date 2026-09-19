// POST /feedback — the in-app bug report / suggestion form.
//   Body: FeedbackReport.toJson() from lib/services/feedback_service.dart:
//   { id, kind, message, link?, email?, app: {version, platform, screen},
//     createdAt, attachments: [{name, mime, base64}] }
//   → 200 { ok: true, id }   (the same client id again → ok, duplicate)
//
// Works signed in or not: an anonymous caller carries the anon key, a
// signed-in one their JWT, and the row records the user if there was one.
// Attachments go to the private `feedback` bucket; the row keeps their
// paths. Replaces tool/feedback/Code.gs.

import { decodeBase64 } from "jsr:@std/encoding@1/base64";
import { error, json, preflight, readJson } from "../_shared/http.ts";
import { callerOf, serviceClient } from "../_shared/supabase.ts";

type Attachment = { name?: string; mime?: string; base64?: string };
type Report = {
  id?: string;
  kind?: string;
  message?: string;
  link?: string;
  email?: string;
  app?: Record<string, unknown>;
  attachments?: Attachment[];
};

const maxAttachments = 4;
const maxAttachmentBytes = 3_000_000;
const safeName = /^[A-Za-z0-9._-]{1,80}$/;
const imageMime = /^image\/(png|jpeg|gif|webp|heic)$/;

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;

  // 16 MB of JSON: four 3 MB screenshots base64'd, with room to spare.
  const report = await readJson<Report>(req, 16_000_000);
  if (!report) return error(400, "invalid_request");

  const kind = report.kind === "feature" ? "feature" : report.kind === "bug" ? "bug" : null;
  const message = typeof report.message === "string" ? report.message.trim() : "";
  if (!kind || !message || message.length > 10_000) return error(400, "invalid_request");
  const clientId = typeof report.id === "string" && report.id.length <= 64 ? report.id : null;
  const link = typeof report.link === "string" ? report.link.slice(0, 2000) : null;
  const email = typeof report.email === "string" ? report.email.slice(0, 200) : null;

  const user = await callerOf(req);
  const db = serviceClient();

  // Insert first, so the row exists even if an attachment upload fails.
  const { data: inserted, error: insertError } = await db
    .from("feedback")
    .insert({
      client_id: clientId,
      user_id: user?.id ?? null,
      kind,
      message,
      link: link || null,
      email: email || null,
      app: report.app ?? null,
    })
    .select("id")
    .single();
  if (insertError) {
    if (insertError.code === "23505") return json({ ok: true, duplicate: true });
    console.error("feedback insert", insertError);
    return error(500, "storage_failed");
  }
  const id = inserted.id as string;

  const stored: { name: string; mime: string; path: string; bytes: number }[] = [];
  for (const [i, a] of (report.attachments ?? []).slice(0, maxAttachments).entries()) {
    const name = typeof a.name === "string" && safeName.test(a.name) ? a.name : `attachment-${i + 1}`;
    const mime = typeof a.mime === "string" && imageMime.test(a.mime) ? a.mime : "application/octet-stream";
    if (typeof a.base64 !== "string") continue;
    let bytes: Uint8Array;
    try {
      bytes = decodeBase64(a.base64);
    } catch {
      continue;
    }
    if (bytes.byteLength === 0 || bytes.byteLength > maxAttachmentBytes) continue;
    const path = `${id}/${name}`;
    const { error: uploadError } = await db.storage.from("feedback").upload(path, bytes, {
      contentType: mime,
      upsert: true,
    });
    if (uploadError) {
      console.error("feedback upload", uploadError);
      continue;
    }
    stored.push({ name, mime, path, bytes: bytes.byteLength });
  }
  if (stored.length > 0) {
    await db.from("feedback").update({ attachments: stored }).eq("id", id);
  }

  return json({ ok: true, id, attachments: stored.length });
});
