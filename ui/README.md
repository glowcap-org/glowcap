# Shared UI assets

The documentation site and rooms app share the product palette, typefaces, the
single-color mark, the mark's play, the logotype lockup, and the product
vocabulary built from the palette (text-safe accent and teal ink, control
radii, overlay cover, chrome frost):

```text
tokens.css   palette, type, the mark's two readings, and shared product tokens
mark.css     how the still mark sits in a box, its bloom, and the wordmark lockup
fonts/       IBM Plex Sans and IBM Plex Mono
```

Each surface keeps its own layout and component styles. The site is static
HTML; rooms is React. Similar-looking controls are not shared CSS. A theme
button or a tab strip does a different job on each surface (a code listing's
folder tabs versus a settings mode switch), and a shared class would make one
of them wrong. If a third glowcap surface needs the same control, extract then. The wordmark
lockup is the extraction that already earned it: rooms' rail and the site
header set the same logotype. Shared *names* still name separate widgets:
`--accent-ink` is one word for readable accent text on both surfaces.

## What belongs here

- **Core tokens:** colors, typefaces, and the mark. Define them once in
  `tokens.css`.
- **Product tokens:** meanings both surfaces share, still in `tokens.css`.
  `--accent-ink` / `--teal-ink` for words. `--accent-fill` / `--on-accent` for
  a filled amber control. `--page-bg` for the warm ground. `--type-tiny` through
  `--type-display` for chrome. `--radius-control` and its siblings.
  `--cover` / `--cover-blur` for a layer over the page (always darkness, not
  theme ink). `--frost` for chrome. `zig build source-check` refuses a
  stylesheet that never closes a comment, string, or brace. It also refuses one
  that hides a `--token:` declaration inside a comment, because the browser
  would drop everything after a dropped `*/`. It refuses a surface that restates
  `--accent-ink` or `--on-accent` or never uses them, `--page-bg`, `--frost`, or
  `--radius-card`, and a rooms sheet that never uses `--type-ui`. Site article
  type stays in rem. Those names are for application chrome.
- **Mark lockup:** `mark.css` owns where the still mushroom sits in its box,
  the bloom it takes under the pointer, and the `.wordmark` drawing. A new
  home takes those classes; it does not copy the numbers.
- **Surface tokens:** what a color means on one surface only, such as a
  chat bubble or a syntax color. Define these in that surface from core
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

There is one mushroom, and it is the shader's. Which reading of it a place gets
is decided by what the mark is doing there.

As a **performance**, it is the shader, and the shader runs only where it is
large enough to be worth a device and where arriving is the point: rooms'
opening screen and its session setup, and the home page's hero. As an
**object**, saying whose page this is, it is the still artwork: the tab icon,
the header and footer lockups, and the project README, which takes the one
still reading that carries light. As a **glyph** among other glyphs,
it is the line drawing: rooms' two mark buttons, a card's lead mark, the rule
at the end of a page.

Spending the shader everywhere made it wallpaper. Keeping it to the two places
that open something is what makes it read as an event again.

The still readings are not a second design. They are traced from the shader's
own render in the settled pose, so they stand in for it exactly.

`site/assets/mark.svg` is that artwork, and it is the standard asset: the
favicon, the square icon the touch icon and the README and the social card all
read, and the two tokens below are all cut from it. All of it is generated.
`zig build gen-mark` renders the shader in the pinned headless browser, traces
that render, and rewrites every one of those files together, so the way to
change the mark is to change the shader. `zig build gen-mark-check` renders
again and fails if any of them has parted from it. The browser is why both
steps sit beside `zig build check` rather than inside it; the half that needs
no browser is in `zig build source-check`, which holds the committed files to
one geometry.

`site/assets/mark-lit.svg` is the same mushroom with its lamps on, and the
project README is the one place that reads it. Its lamps are not a fifth layer
of the drawing: they are found by asking the lit render what it added to the
unlit one, which is the only way to reach the line of light under the brim,
since that line belongs to no unlit tone. The color is measured inside that
same cut. An SVG has no emission and no bloom pass, so the glow is three
passes of the lamp geometry, a wide soft wash and a tight bright one under the
lamps themselves, and the two blurred passes are clipped to the mushroom. That
clip is what makes it read as light inside a thing rather than a halo around
one.

The render it came from is a cel drawing rather than a shaded one. Its
brightness falls into four flat tones with near-empty gaps between them, so
the artwork is four flat fills and not a reduction of anything.
`tokens.css` carries two readings of it. The first is four masks,
`--mark-silhouette`, `--mark-flesh`, `--mark-shade` and `--mark-windows`, each
covering the same frame, so `.icon-mark` stacks four `.mark-piece` children in
one box and paints each its own tone. Masks rather than one finished picture,
because then the drawing is one geometry and the theme is four colors rather
than two whole drawings that have to be kept in step. Those tones are measured off the shader in each theme. It keeps one mushroom
and lights it differently, so on cream the flesh and the rim come up warm and
open. The windows stay as dark as they are at night, being holes rather than
surfaces.
`--mark-line` is the same trace as one-color linework. It is for an ornament
that wants a drawn mark rather than a picture, such as a card's lead mark or
the rule at the end of a page. It is also for a control where the mark is one
glyph among others, which is rooms' two mark buttons. In a control it paints
through the mask over
`currentColor`, the way the stroked glyphs beside it do, so it answers to the
control in every state rather than carrying a color of its own. Its line is the rim band itself, the region between each
outline and the flesh inside it, so it carries the shader's own varying
thickness rather than an even stroke's average of it. A second band, traced
from the cap rendered without its stalk, carries the brim across the stalk
with its bend, which is what says the cap stands in front. The windows are
filled rather than outlined, because these ornaments are set between twenty
and forty pixels and a ring that small closes up. Both ornaments are
pseudo-elements or bare spans, so a mask is the only way to give them the
mushroom, and a mask takes its color from whatever paints it.

The picture stands a fifth larger than the box it is given, because the
shader's canvas does the same. The four percentages on `.mark-piece` in
`mark.css` are what keeps a lockup from shifting when the shader takes the
still mark's place.

The still mark carries no play beyond a bloom under the pointer. Light and its
beats belong to the shader. The picture's tones are measured from the render
rather than picked, so they are literals inside the artwork and carry no theme
arms: the mushroom is a thing seen at night, and its flesh and its rim are the
night's in both themes.

## Light and dark values

Tokens with two values use `light-dark()`:

```css
--ink: light-dark(#3a3027, #f3e6d0);
```

Syrup, the dark face, is the default. A root the reader has not stamped is
dark whatever the desktop prefers, and `data-theme="light"` is the only thing
that turns it off, so each surface sets `color-scheme` under one selector,
`:root:not([data-theme="light"])`. The diagram colors are different: their SVGs
include light fallbacks, while the stylesheet supplies only dark overrides.
Giving those tokens a shared light value would flatten distinct colors in the
artwork. `source-check` holds every surface to that one selector and refuses a
theme decision made from `prefers-color-scheme`.

Do not add a plain custom-property declaration before a `light-dark()`
declaration as a compatibility fallback. Browsers accept any token sequence
when declaring a custom property, so the second declaration wins even where
`light-dark()` cannot be used later.

## Making a change

Edit `site/assets/mark.svg` to change the mark itself, then cut its two tokens
in `tokens.css`, the favicon, and the square icon again from it. Edit
`tokens.css` alone for a shared color or a typeface. Edit `mark.css` to change
where the still mark sits in its box, its bloom, or the wordmark drawing.
Edit `apps/rooms/web/ui/boot.css` to change the rooms opening bloom.

- The rooms app reads the stylesheet on each request, so CSS changes need only
  a browser refresh. Changes to `ui/*.ts` need a server restart because the
  bundle is built at startup.
- Rebuild the site with `zig build site`, or use `zig build docs-serve` while
  editing: Zine reloads content and templates, regenerates CapTP example tabs
  when `site/examples/` changes, and nudges a CSS reload when `ui/tokens.css` or
  `ui/mark.css` changes.

Run `zig build source-check` before committing.
