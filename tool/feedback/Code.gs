/**
 * Lexery feedback relay — a Google Apps Script web app.
 *
 * The app POSTs a bug report or feature suggestion here as JSON (see
 * lib/services/feedback_service.dart, FeedbackReport.toJson) and this
 * mails it, screenshots attached, to TO. Runs on the developer's own
 * Google account, so the app carries no credentials: the URL is the only
 * thing it knows, and all the URL can do is send mail to this one inbox.
 *
 * Setup is in README.md alongside this file.
 */

const TO = 'willcharlesgill@gmail.com';

function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    const kind = data.kind === 'feature' ? 'Feature suggestion' : 'Bug report';
    const app = data.app || {};
    const message = String(data.message || '').trim();

    const body = [
      message,
      '',
      '---',
      'Kind:      ' + kind,
      'Link:      ' + (data.link || '—'),
      'Reply to:  ' + (data.email || '—'),
      'App:       Lexery ' + (app.version || '?'),
      'Platform:  ' + (app.platform || '?'),
      'Screen:    ' + (app.screen || '?'),
      'Sent:      ' + (data.createdAt || '?'),
      'Report id: ' + (data.id || '?'),
    ].join('\n');

    const attachments = (data.attachments || [])
      .filter(function (a) { return a && a.base64; })
      .map(function (a, i) {
        return Utilities.newBlob(
          Utilities.base64Decode(a.base64),
          a.mime || 'image/png',
          a.name || ('attachment-' + (i + 1))
        );
      });

    const options = { attachments: attachments, name: 'Lexery feedback' };
    if (data.email) options.replyTo = data.email;

    MailApp.sendEmail(TO, '[Lexery] ' + kind + ': ' + firstLine(message), body, options);
    return json({ ok: true, id: data.id || null });
  } catch (err) {
    return json({ ok: false, error: String(err) });
  }
}

// A GET in a browser just confirms the deployment is live.
function doGet() {
  return json({ ok: true, service: 'lexery-feedback' });
}

function firstLine(text) {
  const line = text.split('\n')[0].trim();
  return line.length > 70 ? line.slice(0, 67) + '…' : line || '(no message)';
}

function json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
