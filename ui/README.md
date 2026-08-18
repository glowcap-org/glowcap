# Shared UI assets

The documentation site and rooms app share the product palette, typefaces, the
single-color mark, the mark's landing, the logotype lockup, and the product
vocabulary built from the palette (text-safe accent and teal ink, control
radii, overlay cover, chrome frost):

```text
tokens.css   palette, type, mark tokens, and shared product tokens
mark.css     stacked-mark pieces, hover landing, and the wordmark lockup
fonts/       IBM Plex Sans and IBM Plex Mono
```

Each surface keeps its own layout and component styles. That is not a
placeholder for a later component library. The site is static HTML; rooms is
React. Widgets that look cousinly — a theme button, a tab strip — do different
jobs (a code listing's folder tabs are not a settings mode switch), and a
shared class would make one of them wrong. If a third pancake surface needs
the same control, extract then. The mark lockup is the extraction that already
earned it: rooms' rail and the site header are the same drawing. Shared
*names* are not shared widgets: `--accent-ink` is one word for readable accent
text on both surfaces.

## What belongs here

- **Core tokens:** colors, typefaces, and the mark. Define them once in
  `tokens.css`.
- **Product tokens:** meanings both surfaces share, still in `tokens.css`:
  `--accent-ink` / `--teal-ink` for words, `--accent-fill` / `--on-accent` for
  a filled amber control, `--page-bg` for the warm ground, `--type-tiny` through
  `--type-display` for chrome, `--radius-control` and its siblings,
  `--cover` / `--cover-blur` for a layer over the page (always darkness, not
  theme ink), `--frost` for chrome. `zig build source-check` refuses a
  stylesheet that never closes a comment, string, or brace, or that hides a
  `--token:` declaration inside a comment (the browser would drop everything
  after a dropped `*/`), refuses a surface that restates `--accent-ink` or
  `--on-accent` or never uses them, `--page-bg`, `--frost`, or `--radius-card`,
  and refuses a rooms sheet that never uses `--type-ui`. Site article type
  stays in rem; those names are for application chrome.
- **Mark lockup:** `mark.css` owns the four stacked pieces, the hover landing
  (the same timeline as the rooms boot fall, without the loop), and the
  `.wordmark` drawing. A new home takes those classes; it does not copy the
  numbers.
- **Surface tokens:** what a colour means on one surface only, such as a
  chat bubble or a syntax colour. Define these in that surface from core
  tokens.
- **Component rules:** how a surface draws its own controls. Keep these with
  the surface.

Do not repeat a core value. Use `var(--accent)`, for example, rather than its
hex value. `zig build source-check` catches repeated core colors, including
equivalent `rgb()` and `rgba()` forms. The rooms avatar ramp is exempt because
its ten fixed tints must support white initials; `page.css` documents that
exception.

## How the files are shared

Both consumers use symlinks:

- `site/assets/tokens.css`, `site/assets/mark.css`, and `site/assets/fonts/*`
  point here.
- `apps/rooms/web/ui/tokens.css`, `apps/rooms/web/ui/mark.css`, and its
  `fonts/*` point here.

Zine only installs assets referenced by a template. Each font therefore needs
a `<link>` in `site/layouts/templates/base.shtml`; a `url()` inside
`tokens.css` is not enough. Without that link the browser silently synthesizes
the missing face because the font uses `font-display: swap`. The same is true
of `mark.css`: name it from the template or Zine will not ship it.

The rooms server exposes the linked files through an allowlist. Both surfaces
serve `tokens.css` at their root with `fonts/` beside it, so the relative font
URLs work unchanged. Each page loads `tokens.css` before `mark.css` before its
local stylesheet.

## The mark

The full-color pancake image belongs to the site homepage. `--mark-stack` is
the one-color silhouette. The header lockup on both surfaces is four masked
pieces in `.icon-mark`, so hovering the mark replays the stack falling into
place. Ornaments that cannot host children still paint `--mark-stack` as one
mask. `currentColor` controls the colour, so the quiet mark follows the
active theme without another image.

## Light and dark values

Tokens with two values use `light-dark()`:

```css
--ink: light-dark(#3a3027, #f3e6d0);
```

Each surface sets `color-scheme` for the system preference and for its explicit
theme selector. The diagram colors are different: their SVGs include light
fallbacks, while the stylesheet supplies only dark overrides. Giving those
tokens a shared light value would flatten distinct colors in the artwork.
`source-check` keeps the two dark-theme declarations in sync.

Do not add a plain custom-property declaration before a `light-dark()`
declaration as a compatibility fallback. Browsers accept any token sequence
when declaring a custom property, so the second declaration wins even where
`light-dark()` cannot be used later.

## Making a change

Edit `tokens.css` to change a shared color, typeface, or mark silhouette.
Edit `mark.css` to change the stacked landing or the wordmark drawing.

- The rooms app reads the stylesheet on each request, so CSS changes need only
  a browser refresh. Changes to `ui/*.ts` need a server restart because the
  bundle is built at startup.
- Rebuild the site with `zig build site`, or use `zig build docs-serve` while
  editing: Zine reloads content and templates, regenerates CapTP example tabs
  when `site/examples/` changes, and nudges a CSS reload when `ui/tokens.css` or
  `ui/mark.css` changes.

Run `zig build source-check` before committing.
