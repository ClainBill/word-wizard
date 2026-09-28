# Release notes

## 1.0.0 (2) — internal testing

### Play Console "What's new" (≤ 500 characters, paste as-is)

```
<en-GB>
• Back up your lists and study progress to a file, and restore it on any phone (Settings → Your data)
• Crossword help: check a letter, word or the grid, or reveal one — a revealed puzzle scores no points
• Groups choose what they play: a Mini, Midi or Mega crossword, or Word Hunt
• Group leaderboards for the week and all time
• Group crosswords get the AI editor
• Two puzzles a day per game, and up to five groups each
</en-GB>
```

### Built with

`flutter build appbundle --release --dart-define=ENV=dev --dart-define=DEV_TOOLS=true`
(`build/app/outputs/bundle/release/app-release.aab`, signed with the upload
key). Server: migrations `20260927000000` and `20260928000000` and the
`ai-crossword-review` function are on the dev project.

## 1.0.0 (1) — internal testing

### Play Console "What's new" (≤ 500 characters, paste as-is)

```
<en-GB>
First test build of Word Wizard, a dictionary that turns the words you save into study cards and daily puzzles.

• 740,000-word offline dictionary with pronunciations and origins
• Your Lexery: save words, review them with spaced repetition, mark ones you've mastered
• Daily crosswords and a Word Hunt built from your words (Premium)
• A word board to explore on the home screen
• Progress, streaks, a leaderboard
• Sign in with Apple, Google or email

Tell us what breaks: Settings → Report a bug.
</en-GB>
```

### Tester brief (send with the opt-in link)

Thanks for testing Word Wizard. This is the first build outside the
developer's machine, so anything you notice is useful — crashes most of
all, but also anything confusing, slow or ugly.

**Install.** Use the opt-in link, then install from Google Play. The app
is about 500 MB installed: the whole dictionary is on the device and
everything works offline. First launch copies it into place — you'll see
a progress bar for a few seconds.

**What to try**

1. **Look up words.** Search from the home tab; tap a word to see its
   meanings, pronunciation (tap the speaker), origin and forms. Tap any
   word inside a definition to jump to it.
2. **Build your Lexery.** On a word's page tap *Add to Lexery*. Then the
   Study tab: *Start session*, turn cards over, grade them. Try the undo
   arrow, and *I've mastered this word* on something you know cold.
3. **The word board.** The home tab shows a board of tiles growing from
   the word of the day. Drag around, pinch to zoom, tap a tile. Words in
   your Lexery are tinted; tap the shuffle button for a new set.
4. **Puzzles.** Games tab. The Mini crossword is free; the rest is behind
   *Premium*. **Purchases are not live in this build** — the paywall
   shows the offers but buying does nothing yet. To see the paid
   features, Settings → *Debug: fake Premium*.
5. **Read.** Reader tab: paste an article; unfamiliar words are marked,
   tap to look up.
6. **Account.** Settings → *Sign in or create an account*. Email works
   now; Apple and Google buttons will say they aren't set up yet — that's
   expected in this build.
7. **Leaderboard.** Games → the strip at the top. You can look without an
   account; joining needs one and a public name.

**Known in this build**

- Ads are Google's test ads (they say "Test Ad").
- Buying Premium does nothing; use the debug switch above.
- Apple/Google sign-in aren't connected yet.
- The AI editor for crossword clues needs an account; without one the
  Mini sample uses plain dictionary clues.

**How to report.** Settings → *Report a bug or suggest a feature* attaches a screenshot of
the screen you were on and the device details; or just message me. For
a crash, tell me what you were doing right before.

### Checklist for this upload

- [ ] `version: 1.0.0+1` in pubspec.yaml — bump `+N` on every upload.
- [ ] Built with `flutter build appbundle --release --dart-define=ENV=dev
      --dart-define=DEV_TOOLS=true` (the debug switch above needs it).
- [ ] `android/key.properties` present, so the bundle is signed with the
      upload key.
- [ ] Test ad ids still in place (fine for testing; replace for production).
