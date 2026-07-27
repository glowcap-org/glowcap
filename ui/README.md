# The shared UI core

Two surfaces in this repository have a face: the documentation site under
[`site/`](../site/) and the rooms app under
[`apps/rooms/deno/ui/`](../apps/rooms/deno/ui/). They are built and served by
completely different machinery — one is a static site rendered by Zine, the
other is a page served by a Deno process — but they are the same product, and a
reader who moves between them should not feel that they have left.

This directory is what makes that true. It holds the brand itself, once.

```
tokens.css   the palette, the type, the mark
fonts/       IBM Plex Sans and IBM Plex Mono, five faces
```

## What belongs here, and what does not

The layering is worth stating plainly, because it is the rule that keeps this
file short instead of turning into a second stylesheet:

- **Core** lives here. Palette colours, the two typefaces, the mark. These are
  brand facts, and they are true no matter which surface is drawing.
- **Semantic** lives in each surface. What a colour *means* there: the fill of a
  button, a syntax highlight, the bubble your own messages sit in. Built from
  core tokens, never from a fresh colour.
- **Component** lives in each surface too. The rules that draw its own widgets.

A surface may add as many semantic tokens as it likes. It may not restate a core
value: write `var(--accent)`, never the hex again.

`zig build meta-check` holds all of this. The symlinks are still symlinks; the
faces `tokens.css` declares, the files in `fonts/`, and the rooms server's
allowlist are one set; and neither surface writes a core colour as a literal, in
either notation, since a shadow can spell `--ink` as `rgba(58, 48, 39, …)` and a
scan for hex alone would walk straight past it.

There is one exemption: the rooms avatar ramp, which spells its ten tints out
because they carry white initials and cannot follow a theme. `page.css` states
the reason where the values are.

## How the two surfaces reach it

Both consume these files through symlinks, the same mechanism the agent rules
already use to share `.agents/rules` with the editor overlays:

- `site/assets/tokens.css` and `site/assets/fonts/*` link here, so Zine finds
  them as ordinary site assets and installs them beside `style.css`. Every face
  is named by a `<link>` in `base.shtml`, and that is load-bearing rather than
  tidy: Zine installs an asset only when a template asks for its link, and it
  cannot see the `url()` inside `tokens.css`. A face nobody names is simply
  absent, and `font-display: swap` hides that behind a synthesised oblique
  instead of an error.
- `apps/rooms/deno/ui/tokens.css` and `.../fonts/*` link here, and `web.ts`
  serves them from those paths, from an allowlist.

Both surfaces end up serving the stylesheet at their root with `fonts/`
alongside it, which is why the relative font URLs inside `tokens.css` resolve
for both without anything rewriting them at build time.

Each page links `tokens.css` before its own stylesheet, and preloads the two
faces every page needs.

## The mark

The mascot exists twice on purpose, and the difference matters.

The full-colour stack of pancakes is a *picture*. On the site it appears once,
at the front door, where a picture belongs. The rooms app uses only the quiet
version below.

`--mark-stack` is the quiet version: the same stack drawn as a single
silhouette, meant to be used as a CSS mask rather than as an image. Masking
paints it in `currentColor`, so it takes the colour of whatever text it sits
beside and follows the theme without a second asset. That is what lets it be an
ornament — a mark at the end of a page, a mark in a lockup — instead of a
sticker pasted onto the interface.

## How the palette is written

A token that has both a light and a dark value carries them in one declaration:

```css
--ink: light-dark(#3a3027, #f3e6d0);
```

Each surface then sets `color-scheme` under a dark media query and under
`[data-theme="dark"]`, which is what `light-dark()` reads, so the toggle still
beats the system preference in both directions.

The diagram tints do not fold. They have no light value at all: the SVGs name
them as `var(--dia-…, #literal)`, and several distinct pale tints share one
token, so giving one a light value would flatten those colours together and
change the light artwork. They stay declared under both dark arms, and
`meta-check` holds the arms equal and refuses a surface that quietly stops
declaring them.

One thing to know before extending this: the usual two-declaration fallback does
not work for custom properties. Any token sequence is accepted at declaration
time, so a plain value followed by a `light-dark()` value does not degrade — the
second always wins and fails later at substitution. `light-dark()` is a floor,
not an enhancement.

## Changing the brand

The whole point of this directory is that there is one answer, so it is worth
writing the answer down.

To change a colour, a typeface, or the mark, edit `tokens.css`. Nothing else.
Then, to see it:

- **rooms** picks it up on a browser refresh. `web.ts` re-reads the stylesheet
  per request. Editing any `ui/*.ts` module is different: the page bundle is
  built once at startup, so that needs a server restart.
- **the site** needs `zig build site` (or `zig build docs-serve`, which watches).

`zig build meta-check` is what tells you the wiring is still intact.
