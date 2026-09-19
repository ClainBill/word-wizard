/// Where in-app bug reports and feature suggestions go.
///
/// The app has no domain or site yet, so reports are relayed by a Google
/// Apps Script web app on the developer's own account, which mails them to
/// [feedbackEmail] — see `tool/feedback/README.md` for the five-minute
/// setup. When there is a real backend, [feedbackEndpoint] is the one
/// thing to change.
library;

/// The inbox reports end up in. Shown to the user on the form, so they
/// know who reads it.
const String feedbackEmail = 'willcharlesgill@gmail.com';

/// The relay that reports are POSTed to. Empty means "not set up yet":
/// reports are saved to the outbox and sent once a build has one.
///
/// Paste the Apps Script deployment URL here, or pass
/// `--dart-define=FEEDBACK_ENDPOINT=https://script.google.com/macros/s/…/exec`.
const String feedbackEndpoint = String.fromEnvironment('FEEDBACK_ENDPOINT', defaultValue: '');

/// Shown in Settings → About and stamped into every report, so a report
/// says which build it came from.
const String appVersion = '1.0.0';
