# Feedback relay

> Superseded once the backend is deployed: the `feedback` Edge Function in
> `supabase/functions/feedback` accepts the same request and stores reports
> in Postgres with attachments in a private bucket. Point
> `FEEDBACK_ENDPOINT` at it and retire this script. Kept for the
> no-backend interim.

Settings → "Report a bug or suggest a feature" is an in-app form. Because
the app has no backend yet, reports are relayed by a Google Apps Script web
app running on your own Google account, which mails each one — screenshots
attached — to the address in `Code.gs`. Free, no domain needed, and the
app never holds a credential: it only knows the script's URL, and all that
URL can do is send mail to that one inbox.

Until the URL is in a build, the form still works: reports are saved to an
outbox on the device and sent on the first launch that has somewhere to
send them.

## Setup (about five minutes)

1. Go to <https://script.google.com>, **New project**, and replace the
   editor's contents with `Code.gs` from this folder. Name the project
   (e.g. "Lexery feedback") and save.
2. **Deploy → New deployment**. Type: **Web app**. *Execute as:* **Me**.
   *Who has access:* **Anyone**. Deploy, and authorise it when asked (the
   script sends mail as you, so it asks for Gmail permission — you'll have
   to click through "unsafe app" because it isn't verified; it's your own
   script).
3. Copy the **Web app URL** (`https://script.google.com/macros/s/…/exec`).
4. Put it in the app, either

   - in `lib/services/feedback_config.dart` as the `defaultValue` of
     `feedbackEndpoint`, or
   - at build time: `flutter run --dart-define=FEEDBACK_ENDPOINT=https://script.google.com/macros/s/…/exec`

5. Check it from a terminal (`-L` follows the redirect Apps Script answers
   POSTs with):

   ```
   curl -sL -X POST -H 'Content-Type: application/json' \
     -d '{"kind":"bug","message":"relay test","app":{"version":"dev"}}' \
     'https://script.google.com/macros/s/…/exec'
   ```

   It should print `{"ok":true,…}` and a mail should arrive.

## Things to know

- **Editing the script later:** changes only go live through
  **Deploy → Manage deployments → ✎ → Version: New version → Deploy**.
  The URL stays the same.
- **Quota:** a personal Google account can send 100 mails a day through
  `MailApp`, which is plenty for now. A Workspace account gets 1,500.
- **Attachments** arrive as the files the app named them —
  `screen-1-word-hunt.png`, `photo-1.jpg` — and the mail's reply-to is
  set to the reporter's address if they gave one.
- **Later:** when there's a real backend, the app-side contract is just
  "POST this JSON, answer `{"ok":true}`"; replace `feedbackEndpoint` and
  retire the script.
