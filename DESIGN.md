---
name: Anicat
description: Ink-brush restraint meets a library card catalog for a native anime/manga desktop app.
colors:
  background: "#161310"
  foreground: "#ede7dc"
  aizome-indigo: "#8fb8dc"
  aizome-indigo-light: "#a8c9e6"
  card: "#1e1a15"
  surface: "#1e1a15"
  border: "rgba(237, 231, 220, 0.1)"
  text-muted: "color-mix(in srgb, #ede7dc 55%, transparent)"
  danger: "#ef4444"
  danger-light: "#f87171"
  success: "#22c55e"
  success-light: "#4ade80"
  warning: "#eab308"
  warning-light: "#facc15"
typography:
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Inter', 'Segoe UI', sans-serif"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "ui-monospace, 'SF Mono', Menlo, monospace"
    fontSize: "11.5px"
    fontWeight: 400
    letterSpacing: "0.08em"
rounded:
  sm: "6px"
  md: "10px"
  lg: "12px"
  xl: "14px"
  2xl: "16px"
  3xl: "20px"
spacing:
  sm: "8px"
  md: "16px"
  lg: "24px"
components:
  button-primary:
    backgroundColor: "{colors.aizome-indigo}"
    textColor: "{colors.background}"
    rounded: "{rounded.md}"
    padding: "12px 20px"
  button-primary-hover:
    backgroundColor: "{colors.aizome-indigo-light}"
  card:
    backgroundColor: "{colors.card}"
    rounded: "{rounded.xl}"
---

# Design System: Anicat

## Overview

**Creative North Star: "The Sumi Ledger"**

Anicat reads like an ink-brush library ledger, not a streaming-app dashboard: a near-monochrome sumi-ink (dark) or washi-paper (light) base, one restrained aizome-indigo accent, and metadata set in uppercase tabular mono so episode numbers and status lines read like stamped index-card entries. Poster art is the only place color is allowed to be loud — chrome stays quiet on purpose so the art carries the visual weight.

The system explicitly rejects glassy, blurred, streaming-app chrome: an earlier "glass" pass (blur, inner sheen, translucent panels) was deliberately stripped back to solid surfaces with hairline borders. Depth is now a response to interaction (hover lift, focus ring), never an ambient decoration.

Two alternate skins exist — Sakura Zen (cherry-dark/plum-paper, serif headings) and Retro Manga (comic-print halftone, Bangers display type, hard black borders, zero radius) — selected by the user via `data-style`, sharing the same token bridge and layout but replacing character and radius language. This document records the default Ink & Index skin; the alt skins' distinct values live inline in `index.css` and are not re-derived here.

**Key Characteristics:**
- Near-monochrome ink/paper chrome; one live accent (aizome-indigo) used sparingly
- Uppercase tabular mono for all state/metadata text (episode counts, resume position, provider/quality)
- Flat at rest, lift-and-ring on interaction — no ambient shadow, no blur
- Small, consistent macOS-native radius scale (6–20px), never large pill radii on rectangular surfaces
- Dark and light are true parallel themes (sumi-ink / washi-paper), not an inverted single palette

## Colors

Near-monochrome ink/paper neutrals carry the interface; one cool accent is the entire color vocabulary otherwise.

### Primary
- **Aizome Indigo** (`#8fb8dc` dark / `#33617f` light): the single live accent — active tab indicator, primary CTA background, focus ring, watched-progress fill, hover borders. Used sparingly; its rarity is the point.

### Neutral
- **Sumi Ink** (`#161310` background dark / `#f1ece2` washi paper light): app background.
- **Ink Text** (`#ede7dc` foreground dark / `#26221b` light): primary text, drawn from the same ink/paper pairing as the background, never pure black/white.
- **Card Ink** (`#1e1a15` dark / `#faf7f0` light): card, surface, and sidebar background — one step off the page background.
- **Hairline Border** (`rgba(237,231,220,0.1)` dark / `rgba(38,34,27,0.12)` light): the only border treatment in the system; never a heavier stroke outside the Retro Manga skin.
- **Muted Text**: foreground at 55% alpha in dark, 65% in light (the two alphas are not symmetric — light's darker-ink-on-lighter-paper needs more opacity to clear 4.5:1 contrast at the same visual weight).

### Status accents (shared across skins)
- **Danger** (`#ef4444`) / **Success** (`#22c55e`) / **Warning** (`#eab308`), each with a `-light` hover variant. Used only for state (errors, watched confirmation, warnings) — never as decoration.

### Named Rules
**The One Accent Rule.** Aizome Indigo is the only color allowed to be a UI accent outside status states; a second competing accent color is a defect, not a variant.

**The No-Glass Rule.** No `backdrop-filter`, translucent panel fill, or inner sheen outside the two platform-native exceptions (Windows Mica and macOS window vibrancy, which clear the *window's own* material through an intentionally transparent root — not a CSS-simulated blur on top of an opaque surface).

## Typography

**Body Font:** `-apple-system, BlinkMacSystemFont, 'Inter', 'Segoe UI', sans-serif` — SF Pro first so macOS reads as fully native; Inter is the cross-platform fallback.
**Label/Mono Font:** `ui-monospace, "SF Mono", Menlo, monospace`.

**Character:** System sans for everything read as prose or a label; mono is reserved entirely for state metadata, giving it a distinct, slightly technical register from surrounding UI text.

### Hierarchy
- **Body** (400, inherit size, 1.5 line-height): default UI text, sentence case throughout — titles and buttons never go uppercase.
- **Label / Meta** (400, 11.5px, 0.08em letter-spacing, uppercase, tabular-nums): the system's signature text style — episode counts, resume timestamps, provider/quality tags (`EP 21 / 28 · RESUME 12:40 · SUBSPLEASE 1080P`).

### Named Rules
**The Sentence-Case Rule.** Titles, buttons, and body copy stay sentence case. Uppercase is reserved entirely for `.meta-mono` state metadata — using it for emphasis elsewhere breaks the one signal that tells a viewer "this text is data, not prose."

## Layout

Content sits in a max-width column (`~1150px`) with responsive horizontal padding stepping from `px-4` (mobile) to `px-14` (desktop). A fixed sidebar (`.glass-fixed`, despite the legacy class name it is solid, not glass) anchors navigation; detail pages replace the current view full-page rather than overlaying it. Density is comfortable, not compact — list rows and cards use 8–16px internal rhythm (Tailwind's default scale), stepping to 24px between major sections.

## Elevation & Depth

Flat by default: surfaces carry no ambient shadow at rest. Depth appears only as a response to interaction — a card hover lifts 2px with a soft directional shadow, and focus adds the accent ring on top of (not instead of) that lift. This is a deliberate reversal of an earlier "glass" era; nothing in the default skin should return to ambient blur or resting shadow.

### Shadow Vocabulary
- **Hover lift** (`box-shadow: 0 10px 28px rgba(0,0,0,0.45)`, `transform: translateY(-2px)`): the only resting-to-active transition on cards.
- **Focus ring** (`box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent-color) 70%, transparent), 0 0 0 4px var(--background)`): keyboard/spatial-nav focus, layered outside the hover lift's shadow when both are active.
- **Primary CTA glow** (`shadow-accent/10`): the one static (non-hover) shadow in the system, reserved for the single primary action button on the detail page.

### Named Rules
**The Flat-By-Default Rule.** No box-shadow at rest anywhere except the primary CTA. Shadow exists only as a state response (hover, focus), never as ambient surface decoration.

## Shapes

Small, consistent macOS-native radii: 6px (sm) through 20px (3xl), used on chips and small squares (6px) up through cards and modals (12–16px). Radii deliberately stay below the "big friendly" pill-radius look of the app's earlier v3 identity — native surfaces sit between 6 and 16px, not 24px+. The one uppercase-metadata primitive (`.meta-mono`) and thin poster-progress ticks are the system's recurring signature marks, not radius or shadow.

## Components

Restrained and precise: hairline borders, no glass, no inner sheen; the mono-uppercase metadata label is the one recurring flourish.

### Buttons
- **Shape:** 10px radius (`rounded-md`) standard; small icon-only actions may use 6–8px.
- **Primary:** accent background (`bg-accent`), background-colored text (`text-background`), `px-5 py-3`, bold 13.5px label, static `shadow-lg shadow-accent/10`.
- **Secondary / Ghost (`.glass-button`):** solid surface-color fill (not translucent, despite the class name) with an inset 1px hairline border; hover darkens toward foreground by 20% via `color-mix`.
- **Press feedback:** `active:scale-95` on every interactive control; on the mobile shell, press also drops opacity to 0.85.

### Cards / Containers (`.card-glow`)
- **Corner Style:** 12–16px radius depending on context.
- **Background:** `var(--card-color)`, one step off page background.
- **Shadow Strategy:** flat at rest; hover raises 2px with the hover-lift shadow (see Elevation).
- **Border:** hairline `var(--border-color)`; on focus, the border and ring both switch to accent.

### Inputs / Selects
- **Style:** surface-color background, hairline border, no inner glow at rest.
- **Focus:** the shared focus-ring treatment (accent ring + background-colored outer ring), never a color-shifted border alone.

### Navigation (sidebar, `.glass-fixed`)
- **Style:** solid surface-color fill (transparent only under the two native-material exceptions), single hairline border on the trailing edge, no shadow.

### Watch-grid squares (`.watch-sq`, signature component)
Per-episode indicator on the detail page: 26×26px, 5px radius, mono-numeral label. States: default (hairline border, muted text), hover (accent border + full-opacity text), watched (accent-dim fill, transparent border, accent text), current (accent border, full-opacity text). This is the system's most literal expression of the ledger metaphor — each square is a stamped record.

## Do's and Don'ts

### Do:
- **Do** keep the accent to one live use per view outside status colors (The One Accent Rule).
- **Do** set state metadata (episode counts, resume position, quality/provider tags) in `.meta-mono` — uppercase, tabular, 11.5px, 0.08em tracking.
- **Do** express depth only as an interaction response — hover lift, focus ring — never as resting decoration.
- **Do** keep radii in the 6–20px native range; nothing larger on rectangular surfaces.

### Don't:
- **Don't** reintroduce `backdrop-filter` blur, translucent panel fills, or inner sheen on any surface outside the Windows Mica / macOS vibrancy exceptions, which clear real OS-level material rather than simulating it.
- **Don't** uppercase titles, buttons, or body prose — uppercase is reserved for metadata.
- **Don't** add a resting box-shadow to a card, panel, or button outside the single primary-CTA glow.
- **Don't** carry Ink & Index's exact hex values or radius overrides into the Sakura Zen or Retro Manga skins — each alt skin defines its own palette and form language and is documented separately in `index.css`, not re-derived from this default.
