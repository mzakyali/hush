# Hush — brand guidelines

Hush is a quiet piece of hardware on your desk. The brand world is the
**instrument panel**: dark charcoal surfaces, a single hot signal colour,
numbers set like readouts, voice drawn as a dot-matrix display. The design
system in [`DESIGN.md`](../../DESIGN.md) is the source of truth for tokens;
this document covers how the identity is used outside the app.

## Name and voice

- The product is **Hush** — capital H, lowercase rest. Never "HUSH" or
  "hush" in prose. Lowercase `hush` is fine in code, paths, and package
  names.
- Tagline: **Speak into any app. Nothing leaves your Mac.**
- One-liner: Local voice dictation for macOS — hold a key, talk, get
  cleaned-up text wherever you're typing.
- Short description (~1 sentence): Hush is a local, offline-first dictation
  app for macOS. Hold fn, speak in English, Indonesian, or a mix of both,
  and cleaned-up text lands in the app you're working in.
- Long description: Hush records your voice with a global hotkey,
  transcribes it on-device with Whisper, cleans up fillers and punctuation
  with a local LLM, and inserts the result into the app that was focused
  when you stopped. It learns from the edits you make after pasting.
  Nothing — audio or text — ever leaves your Mac.

**Voice:** quiet, precise, honest about limits. Say what it does and what
it doesn't. No hype, no exclamation marks, no emoji.

## Colour

Token names and roles are defined in `DESIGN.md`. The headline values:

| Role | Value |
|---|---|
| Background | `#0B0B0C` |
| Tile / raised surfaces | `#161618` / `#1F1F22` |
| Primary (text, lit elements) | `#F2F0EC` |
| Mark bars (cream) | `#F4EFE6` |
| Signal | `#FF5B2E` — the voice, the active thing. One signal focal area per composition. |

Everything else (hairlines, secondary text, dot-off, ok/warn/error) comes
straight from `DESIGN.md` — use the tokens, don't invent new values.

## Typography

| Role | Face | Treatment |
|---|---|---|
| Display / wordmark | Instrument Serif, Regular | −0.02em tracking |
| Labels / readouts | Geist Mono, Medium | UPPERCASE, +0.06em tracking |
| Body | SF Pro (system font) | — |

Both bundled fonts are OFL-1.1 (licences in `App/Fonts/`). SF Pro is the
system font — use it where system text would appear, don't substitute
another sans.

## The mark

Five vertical capsule bars; the centre bar is the signal colour. It
descends directly from the app icon (`App/HushIcon.icon/`).

- `hush-mark.svg` — cream bars + signal centre bar, transparent background.
  Preferred on dark surfaces.
- `hush-mark-mono.svg` — all bars `#0B0B0C`, for light backgrounds and
  single-colour contexts.
- `hush-mark-512.png` — raster export.
- `hush-app-icon.svg`, `hush-app-icon-1024.png` — rounded-square app icon
  (gradient `#26262A` → `#0E0E10`). The shipping icon is the Icon Composer
  document; these are for external use.

Rules:
- Clear space: at least two bar-widths on all sides.
- Minimum size: 16 px high; below that the bars read as noise.
- Prefer the mark on `bg.window` (#0B0B0C) or similar dark surfaces. On
  light, use the mono version.
- Don't recolour the centre bar, don't add effects (shadows, glows,
  gradients on the bars), don't stretch or rotate, don't rearrange the
  bar heights.

## The dot-matrix wave

The signature motif — voice as a dot-matrix display. 25 columns × 7 rows;
per column `y = A·sin(πx)·sin(2π·1.6x − φ)` so the ends taper onto the
centre line, with an echo strand at opposite phase, 0.6× amplitude, 35%
opacity. Lit dots cream; the centre columns hot in signal; unlit dots (when
a grid is drawn) white at 9%.

Use it horizontally, once per composition, as a texture or divider — never
as a background for text.

## Asset inventory

| File | Contents |
|---|---|
| `hush-mark.svg` | Primary mark (cream + signal, transparent) |
| `hush-mark-mono.svg` | Mono mark (`#0B0B0C`, transparent) |
| `hush-app-icon.svg` | App icon, pure-shape approximation |
| `hush-mark-512.png` | Mark raster, 512 px |
| `hush-app-icon-1024.png` | App icon raster, 1024 px |
| `banner.png` | 1280×640 banner / GitHub social preview |
| `banner@2x.png` | 2560×1280 banner (README header) |

## Regenerating

```bash
swift scripts/render-brand.swift   # run from the repo root
```

Renders all PNGs above into `docs/brand/`. Fonts are registered from
`App/Fonts/` at runtime; the script fails loudly if a font is missing.
