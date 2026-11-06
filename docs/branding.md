# GDriveShelf logo

`gdriveshelf.koplugin/resources/logo.png` is the original raster mark generated on 2026-11-06 with OpenAI's built-in `image_gen.imagegen` tool in Codex, using the imagegen skill. No CLI/API fallback was used. The generated PNG was copied unchanged into the project, preserving transparency.

The bold triangular ribbon recalls Drive's geometry; the transparent open book and shelf-like base identify the plugin's reading-library purpose. It is an independent GDriveShelf mark, not the official Google Drive logo. Use it on a light background, preserve its square canvas and clear padding, and scale proportionally. The source is 1254 × 1254 pixels (245,674 bytes); UI code should constrain its displayed dimensions. Visually checked on white at large size and at 128, 64, and 32 pixels.

## README presentation

`docs/logo-readme.svg` is a self-contained presentation wrapper: a pure white rectangle behind an embedded, byte-for-byte copy of the original PNG. The artwork, 1254 × 1254 canvas, placement, and padding remain exact. The white background makes the black mark visible in both light and dark README themes. This wrapper is code-native presentation markup, not a redrawn logo or a new generated mark; keep the transparent PNG for the KOReader UI.

Verified in Chromium on white and dark backgrounds. The rendered wrapper is fully opaque (all alpha values are 255), with pure white corner pixels. The embedded PNG matches the original SHA-256 `f9ed432178e7d5cf8788825319b82311336e071e3c4ee966af5ea51655d79de5`. The wrapper is 327,877 bytes; its embedded raster avoids external image dependencies.

## Generation prompt

```text
Use case: logo-brand
Asset type: finished monochrome raster logo for GDriveShelf, an independent Google Drive book-library plugin for KOReader e-ink readers, and its repository.
Primary request: One original bold geometric emblem: a three-sided triangular ribbon/loop that gives a clear visual hint of the Google Drive triangle, integrated with a simple open-book silhouette in its central negative space. Preserve an independent identity rather than reproducing Google's exact official emblem. Use a broad stable lower horizontal base like a shelf and two rising diagonal ribbon sides; the central opening should suggest the two pages of an open book with a broad, clean central fold. Make the silhouette immediately legible at 32 pixels.
Style/medium: professional flat vector-like logo rendered as a crisp PNG, precise simple geometric forms, substantial continuous strokes, minimal contour complexity.
Composition/framing: one finished mark, centered in a square canvas, roughly 72 percent of canvas width, with generous even transparent padding. No variants, no presentation sheet.
Color palette: pure black foreground only; genuine fully transparent background and transparent negative space. Edge antialiasing is allowed; no gray fill.
Text: none.
Constraints: no text, no letters, no brand wordmarks, no tiny lines or details, no shadows, no gradients, no texture, no mockup, no colored parts. Do not copy the exact Google Drive logo. Produce a single balanced symbol ready for small e-ink UI use.
```
