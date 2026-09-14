# Word Wizard — design explorations

## Current: Interface study 02

Open `paper-worlds/dist/index.html` directly, or serve `paper-worlds/dist` locally. No build or dependencies are required.

Rebuilt from the current Flutter source: SearchScreen, EntryCard, AppShell, AppTheme, StudyScreen, and StudySessionScreen. This is an HTML reconstruction with sample data, not captured Android screenshots. It follows the existing sans-serif Material layout, 12px corners, six navigation destinations, study stats, forecast, and four review grades. The footer identifies the illustrative data. Navigation icons are approximate symbols.

The surrounding portfolio is white-gray. App screens use the existing light palette: #E9EAE0 background, #F5F5EF surfaces, #1E2A22 text, #8A5A22 primary, #35604F secondary.

A seeded 256×256 pixel monochrome noise tile is generated once, repeated at its native CSS size, and composited as a fixed full-screen overlay at 28% opacity. It never animates or regenerates while scrolling. The intensity slider ranges from 0–50%, and the toggle allows direct comparison. Unlike the previous SVG turbulence treatment, the pixels have the full 0–255 luminance range. The layer ignores pointer input and is hidden from assistive technology.

Working demo interactions: search the six sample words, clear the search, start a sample session, reveal a definition, and use Again/Hard/Good/Easy to advance. No scheduling or persistence is implemented. The app itself is untouched.

Previous white-edition page source is retained in `paper-worlds/archive-white-edition/`. The antique image in `dist/assets` is unused.
