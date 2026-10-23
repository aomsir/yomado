# yomado image assets

Generated with the built-in `image_gen` tool. These are original AI-generated concept illustrations, not screenshots of a local desktop or evidence of tested monitor-off operation.

- `yomado-logo.png`: the selected night-window app icon, identical to `../../app/Resources/night-window.png`; the outer corners are transparent, while the deep navy tile stays opaque.
- `yomado-usage-night-window.png`: the usage illustration updated with the selected night-window icon and the existing lowercase wordmark.
- `../../app/Resources/night-window.png`: the canonical application icon. `Yomado.icns` is generated from the unchanged source via `bash scripts/build-icon.sh`, which centers the artwork on transparent canvases with app-icon padding before packaging the standard macOS sizes.

The old cyan four-pane window identity has been replaced in the published assets. Both language READMEs use the same current brand images; their narrated demo videos remain at the beginning.

## Selected application icon prompt

Selected from five independently generated concepts. Only the chosen concept is packaged in the application.

```text
Use case: logo-brand. Asset: one original macOS app icon concept for lowercase yomado, a software-only virtual display that keeps a graphical workspace available for visual computer-use agents when the physical monitor is off. Make a refined memorable icon, strong silhouette legible at 32 pixels, centered on an opaque rounded-square app tile, filling roughly 85% of a square image. Front-facing flat icon artwork with restrained material depth, precise geometry, generous inner breathing room. No words, letters, numbers, captions, watermark, presentation board, device mockup, photo, robots, eyes, circuit traces or decorative stars. The supplied conceptual direction is the sole central mark. This is an app icon, not a website illustration. Direction: Night window. A single distinctive upright window aperture of warm pale ivory light, set inside a deep midnight indigo tile. One subtly rounded upper corner and a small curved moon-shaped notch integrated into the window's upper inner corner make a recognizable custom silhouette. The luminous interior suggests a workspace still awake at night. Quiet, precise, elegant. Avoid literal desktop computers and busy window grid.
```

### Transparent exterior edit

```text
Use case: background-extraction. Edit target: the attached selected yomado macOS app icon, option 1 Night Window. Change ONLY the white exterior outside the deep midnight indigo rounded-square tile to genuine alpha transparency, keeping the tile, luminous cream moon-notched window mark, dimensions, framing, geometry, colors, texture and glow precisely unchanged. Keep all dark tile pixels opaque, including the moon-shaped notch, and all cream pixels opaque. Do not remove the dark background tile. No redesign, no sharpening, no added text, no white matte around edges. Output a square PNG with truly transparent exterior corners, suitable for packaging as a macOS .icns.
```

## Original usage illustration prompt

The initial composition was generated with this prompt. Its original title was later changed to lowercase, and the selected night-window icon was applied with the final edit below.

```text
Use case: illustration-story
Asset type: wide GitHub README usage-example hero image, approximately 16:9 landscape.
Primary request: Create a polished, easy-to-understand conceptual illustration for Yomado, a native macOS virtual display for graphical AI agents. Explain the intended scenario: a Mac remains awake and a graphical agent can use a virtual desktop while the physical monitors are switched off.
Scene and composition: clean editorial technology illustration on a deep midnight navy background, restrained warm moonlight and soft cyan accents, generous margins, crisp shapes, subtle grain, sophisticated luminous depth. Two real physical monitors sit together on the LEFT with completely dark matte screens, switched off, no lit content. A small silver desktop Mac-like computer below them has a tiny active status light. On the RIGHT, spatially separate and clearly beyond both physical monitors, a large FLOATING virtual-desktop panel has no stand or physical bezel, just a thin softly glowing cyan dotted outline. A subtle dotted link connects the awake computer to this virtual panel. Do not position the virtual panel between the physical monitors.
The virtual desktop contains TWO elegant simplified illustrative application windows: one labeled "Blender" with an orange low-poly garment mannequin and 3D mesh viewport, the other labeled "Garment design" with a pale fabric jacket on a mannequin and simple flat 2D sewing patterns. Use readable illustrative content, not a detailed or supposedly authentic screenshot. Include one clear agent cursor in the virtual desktop. Keep UI chrome abstract and minimal, no fabricated operational metrics.
Typography: refined modern sans serif, strong visual hierarchy, large readable text, few labels only.
Text (verbatim): top-left headline "Yomado", subtitle below "A virtual workspace for graphical agents". Label below the two dark monitors "Physical displays off". Label near computer "Mac stays awake". Label above floating panel "Virtual display". Small label within floating panel "Agent workspace". Window labels "Blender" and "Garment design". Tiny restrained bottom-right footer "Concept illustration".
Constraints: This is a usage CONCEPT, not proof of a successful test. No separate OS or security sandbox imagery, no shield, no isolated mouse/keyboard implication. No people, robot mascot, phone, clouds, extra hardware, watermarks, power savings percentages, fake app status badges or claims. No real screenshots, usernames, email, local file paths, project names or machine identifiers. Do not add a third physical monitor. Make the picture visually appealing and the main physical-versus-virtual relationship instantly legible.
```

## Current usage illustration edit (2026-10-13)

Built-in image generation edit. Reference 1: the previous usage illustration. Reference 2: `../../app/Resources/night-window.png`. Only the upper-left symbol was replaced; the scene and lowercase wordmark were preserved.

```text
Use case: precise-object-edit. Edit target is image 1, the existing wide yomado README product usage illustration. Image 2 is the authoritative new app icon to insert; it is not a new illustration style. Change ONLY the obsolete bright blue four-pane window/crescent icon at the upper left of image 1 to the EXACT new app icon from image 2: a dark navy rounded square containing a warm ivory glowing single upright window shape with a rounded top-left, rounded lower corners, and a deep circular moon-shaped notch cut from its upper-right. Preserve that icon silhouette and colors accurately, no four panes and no extra moon symbol. Place it at the same size and position as the obsolete icon, with its full dark navy rounded-square background. Keep the lowercase white 'yomado' wordmark to its right unchanged. Preserve the entire original scene and composition: nighttime workspace, both dark physical monitors, warm desk lamp, Mac Studio, virtual display on the right with two stylized Blender/garment-design windows and jackets, all labels, typography, blue dotted frame, cursor, foreground chair and right-bottom 'Concept illustration'. Preserve original landscape aspect ratio and detail. Do not redesign or introduce new words, do not add logos elsewhere. High fidelity surgical brand update for an existing published README illustration. Output one final edited wide illustration.
```
