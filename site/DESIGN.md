---
name: YuE Studio
description: A warm record-sleeve identity for a local music studio.
colors:
  paper: "#f5f0e3"
  ink: "#24201a"
  dark: "#211a16"
  orange: "#be4313"
  muted: "#665a4c"
  light-muted: "#c9bcaa"
  line: "#d5caba"
  pale-orange: "#f1ab7c"
  dark-line: "#645241"
  orange-hover: "#9b340c"
  paper-hover: "#e8dcc7"
typography:
  display:
    fontFamily: "Barlow Condensed, sans-serif"
    fontSize: "clamp(4.2rem, 7.5vw, 6rem)"
    fontWeight: 600
    lineHeight: 0.94
    letterSpacing: "-0.025em"
  headline:
    fontFamily: "Barlow Condensed, sans-serif"
    fontSize: "clamp(2.6rem, 4.2vw, 4rem)"
    fontWeight: 600
    lineHeight: 1.02
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Barlow Condensed, sans-serif"
    fontSize: "2.2rem"
    fontWeight: 600
    lineHeight: 1.02
    letterSpacing: "-0.02em"
  body:
    fontFamily: "Barlow, sans-serif"
    fontSize: "18px"
    fontWeight: 400
    lineHeight: 1.55
  label:
    fontFamily: "Barlow, sans-serif"
    fontSize: "16px"
    fontWeight: 600
    lineHeight: 1.55
rounded:
  action: "4px"
  screenshot: "7px"
spacing:
  compact: "14px"
  small: "18px"
  medium: "24px"
  large: "30px"
  section-gap: "40px"
  wide: "60px"
components:
  button-primary:
    backgroundColor: "{colors.orange}"
    textColor: "{colors.paper}"
    rounded: "{rounded.action}"
    padding: "17px 25px"
  button-primary-hover:
    backgroundColor: "{colors.orange-hover}"
  button-small:
    backgroundColor: "{colors.orange}"
    textColor: "{colors.paper}"
    rounded: "{rounded.action}"
    padding: "12px 17px"
  button-light:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.action}"
    padding: "17px 25px"
  button-light-hover:
    backgroundColor: "{colors.paper-hover}"
  text-link:
    typography: "{typography.label}"
  navigation:
    typography: "{typography.label}"
  studio-tabs:
    backgroundColor: "{colors.dark}"
    textColor: "{colors.light-muted}"
  disclosure:
    textColor: "{colors.ink}"
    padding: "20px 32px 20px 0"
---

# Design System: YuE Studio

## Overview

**Creative North Star: "Community liner notes"**

A generous record sleeve for a native music studio. Warm ivory, brown-charcoal and the established orange tuning-fork identity frame music-poster typography, tactile vinyl and speaker imagery, and complete real application screenshots. The voice is welcoming, direct and grounded in music.

The system is spacious and editorial: large color fields, compact display headlines, readable supporting copy and ruled content groups. Most surfaces remain flat. Authentic screenshots supply product evidence; generated photographs supply campaign atmosphere and remain identified as such.

**Key Characteristics:**
- Warm ivory, burnt orange and brown-charcoal inherited from the app.
- Self-hosted Barlow Condensed headlines with readable Barlow supporting text.
- Large authentic app screens paired with tactile campaign imagery.
- Quiet rules, small corners and generous space instead of repeated card chrome.
- Keyboard-visible interactions and optional, reduced-motion-aware reveals.

This is the implemented website system, recorded from `index.html`, `styles.css`, `app.js` and settled desktop/mobile captures in `.impeccable/qa/`. The selected direction is candidate 6, seed `d90cfd60`; the original app identity remains authoritative. Product capabilities and factual constraints live in `PRODUCT.md`.

## Colors

The palette pairs warm paper and brown-black ink with confident burnt orange; pale warm tones keep the charcoal region readable.

### Primary

- **Burnt orange** (`orange`): downloads, headline emphasis, image framing and the community section.
- **Deep burnt orange** (`orange-hover`): primary action hover state.
- **Pale apricot** (`pale-orange`): links and keyboard focus within dark sections.

### Neutral

- **Ivory paper** (`paper`): page canvas and light text on dark or orange backgrounds.
- **Brown-black ink** (`ink`): principal text and light-button labels.
- **Studio charcoal** (`dark`): the Create/Master presentation region.
- **Warm muted ink** (`muted`): explanatory copy on ivory.
- **Light warm grey** (`light-muted`): supporting copy and metadata on charcoal.
- **Paper rule** (`line`): separators on light surfaces.
- **Charcoal rule** (`dark-line`): separators on dark surfaces.
- **Pressed ivory** (`paper-hover`): light-button hover state.

**The App Identity Rule.** Keep the orange tuning-fork mark and the warm orange, ivory and charcoal relationship recognizable.

## Typography

**Display Font:** Barlow Condensed, with sans-serif fallback.
**Body Font:** Barlow, with sans-serif fallback.

Self-host the regular and semibold Barlow files and Barlow Condensed Semibold from `assets/fonts/`, using font-display swap. The narrow display face supplies musical poster character while the wider body face keeps descriptions, setup instructions and controls legible. Headings use balanced text wrapping; emphasis in the hero changes color without switching to italic.

### Hierarchy

The normative default roles are in the frontmatter. Display is reserved for the hero, headline for section headings, title for subsection headings, body for reading and label for secondary controls. The scale is editorial rather than a fixed mathematical ratio. Individual section titles are sized for their context; do not promote each local override into a new type system.

Body paragraphs cap at 70 characters, with narrower introductions and supporting copy. Below the mobile breakpoint, body text uses 17px and the hero uses `clamp(4.2rem, 12vw, 5.8rem)`. Metadata ranges from 13px to 15px. Controls remain sentence case.

**The Two Voices Rule.** Use Barlow Condensed for headings and Barlow for reading, controls and metadata.

## Layout

The shared desktop container is capped at 1280px, with a width of `calc(100% - 112px)`. At 1050px and below it uses a 64px total inset; at 760px and below it uses a 40px total inset. Section backgrounds may extend edge to edge while content remains aligned to the shared container.

Desktop combines paired introduction columns, a photographic triptych, a copy/screenshot studio grid, three setup columns and a two-column FAQ. Rules organize details without surrounding each item in a card. The recurring spacing samples in the frontmatter are observed values, not an imposed uniform spacing scale.

At 760px and below, introductions and major grids stack, the navigation wraps into its own row, download actions broaden, setup steps become numbered rows, and footer links wrap. The hero screenshot comes first above two photographic crops. At 1500px and above, the triptych center is constrained between 650px and 760px. Do not make this landing-page triptych a mandatory layout for every future surface.

## Elevation & Depth

Flat color fields and fine rules establish most hierarchy. Material photographs provide tactile depth; the hero app screenshot alone receives a soft ambient shadow (`0 14px 35px #32170855`). Other app screenshots use the same gentle corner shape without floating-card treatment. Preserve this distinction rather than spreading the hero shadow to every content group.

**The Evidence Rule.** Preserve the geometry of real app screenshots; campaign imagery may be cropped, but must not impersonate product UI.

## Shapes

Actions use modest corners; screenshots use slightly softer corners, as specified by the two radius tokens. Content groups use straight horizontal rules. Inline SVG arrows and download symbols share unfilled, rounded strokes. FAQ controls use simple geometric plus/minus indicators. The established tuning-fork asset remains the brand mark; its silhouette is not replaced with a typographic symbol.

## Components

### Buttons

Filled, readable and direct. The primary action uses burnt orange and ivory; the community variant uses ivory and ink. Standard buttons have a minimum height of 52px, with a compact header form at 46px (44px on mobile). Icons are 21px with 1.75px strokes. Hover changes the fill without adding motion. Focus uses a 3px outline with a 5px offset; its color adapts to orange, charcoal or paper context for visibility.

### Text links

Secondary actions use semibold text and an inline 19px external arrow where appropriate. Hover underlines action links; reading links retain their visible underline with a 4px offset. The design does not rely on arrows alone for an accessible name.

### Navigation

A simple horizontal text navigation sits between the brand and download action. Hover takes the orange accent. On mobile it moves below the brand/action pair with a top rule and evenly distributed destinations. The skip link becomes visible on focus.

### Studio tabs and panels

The dark studio region uses a horizontal pair of text tabs with a fine bottom rule. Selected tabs receive ivory text and a warm orange underline; inactive tabs use light muted text. Panels pair description and full authentic screenshot. The enhancement supplies tablist/tab/tabpanel semantics, roving focus, Left/Right and Home/End keys. Without JavaScript, both panels remain readable.

The sole content animation reveals the selected screenshot over 450ms using `cubic-bezier(.16,1,.3,1)` and a subtle clip change. Reduced-motion preference disables it and smooth scrolling. Content remains visible without animation.

### Ruled setup groups

These are open content columns, not cards. A paper rule, condensed orange number, compact heading and readable paragraph establish order. Mobile aligns each number beside its heading and copy.

### FAQ disclosures

Native details/summary controls retain keyboard behavior. A horizontal rule separates each entry. The geometric plus becomes a minus when open; the answer appears below without a transition. Summary rows have a minimum height of 64px. Do not replace these with decorative, inaccessible imitation controls.

## Do's and Don'ts

### Do:
- Do use the existing orange tuning-fork identity and warm palette.
- Do self-host Barlow fonts and retain their OFL notices.
- Do preserve complete app screenshot proportions and label actual application imagery.
- Do use inline SVG icons or CSS geometry for simple interface symbols.
- Do retain visible keyboard focus, semantic controls and a reduced-motion path.
- Do use ruled groups and open space for supporting content.

### Don't:
- Don't replace real app screens with generated UI.
- Don't treat generated campaign images as documentary photography.
- Don't introduce ornamental glass, gradients or repeated floating cards into the established web system.
- Don't turn optional motion into a prerequisite for reading or navigating.
- Don't import the website's poster layout into the native application as an assumed redesign.
