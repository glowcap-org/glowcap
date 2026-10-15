# Shared UI assets

The documentation site and rooms app share the product palette, typefaces, the
single-color mark, the mark's play, the logotype lockup, and the product
vocabulary built from the palette (text-safe accent and teal ink, control radii,
overlay cover, chrome frost):

```text
tokens.css   palette, type, the mark's two readings, and shared product tokens
mark.css     how the still mark sits in a box, its bloom, and the wordmark lockup
fonts/       IBM Plex Sans and IBM Plex Mono
```

Each surface keeps its own layout and component styles. The site is static
HTML, and Rooms is React.

Controls that look alike are not shared CSS. A theme button or a tab strip does
a different job on each surface (folder tabs on a code listing, a mode switch in
settings), and one shared class would be wrong for one of them. Extract a shared
control only when a third glowcap surface needs it. The wordmark lockup is
shared because the Rooms sidebar and the site header show the same logotype.
Shared token *names* still describe separate widgets: `--accent-ink` means
readable accent text on both surfaces.

## What belongs here

- **Core tokens:** colors, typefaces, and the mark. Define them once in
  `tokens.css`.
- **Product tokens:** meanings both surfaces share, still in `tokens.css`:
  - `--accent-ink` / `--teal-ink` for words
  - `--accent-fill` / `--on-accent` for a filled amber control
  - `--page-bg` for the warm ground
  - `--type-tiny` through `--type-display` for application chrome (site article
    type stays in rem)
  - `--radius-control` and its siblings
  - `--cover` / `--cover-blur` for a layer over the page (always darkness, not
    theme ink)
  - `--frost` for chrome
  - `--mycelium` / `--mycelium-pulse` for the threads under both pages and the
    light that runs through them

  `zig build source-check` refuses:
  - a stylesheet that never closes a comment, string, or brace
  - a stylesheet that hides a `--token:` declaration inside a comment, because
    the browser would drop everything after a dropped `*/`
  - a surface that restates `--accent-ink` or `--on-accent`, or never uses them,
    `--page-bg`, `--frost`, or `--radius-card`
  - a rooms sheet that never uses `--type-ui`
- **Mycelium:** `apps/rooms/web/ui/mycelium.ts` grows the network of threads
  behind every page of both surfaces, and both call its `startMycelium()`. A
  surface that paints its own full-page ground hides it, so a page shows the
  body's `--page-bg` instead of repainting it.
- **Mark lockup:** `mark.css` owns where the still mushroom sits in its box,
  the bloom it takes under the pointer, and the `.wordmark` drawing. A new
  home takes those classes. It does not copy the numbers.
- **Surface tokens:** what a color means on one surface only, such as a
  chat bubble or a syntax color. Define these in that surface from core
  tokens.
- **Component rules:** how a surface draws its own controls. Keep these with
  the surface.

Do not repeat a core value. Use `var(--accent)`, for example, rather than its
hex value. `zig build source-check` catches repeated core colors, including
equivalent `rgb()` and `rgba()` forms. The rooms avatar ramp is exempt because
its fixed tints must support white initials, and `page.css` documents that.

## How the files are shared

Both consumers use symlinks:

- `site/assets/tokens.css`, `site/assets/mark.css`, and `site/assets/fonts/*`
  point here.
- `apps/rooms/web/ui/tokens.css`, `apps/rooms/web/ui/mark.css`, and its
  `fonts/*` point here.

Zine only installs assets referenced by a template. Each font therefore needs a
`<link>` in `site/layouts/templates/base.shtml`, because a `url()` inside
`tokens.css` is not enough. Without the link the browser silently synthesizes
the missing face, since the font uses `font-display: swap`. Name `mark.css` from
the template too, or Zine will not ship it.

The rooms server exposes the linked files through an allowlist. Both surfaces
serve `tokens.css` at their root with `fonts/` beside it, so the relative font
URLs work unchanged. Each page loads `tokens.css` before `mark.css` before its
local stylesheet.

## The mark

There is one mushroom, and it comes from the WebGPU shader in the
`apps/rooms/web/ui/mark_gpu*.ts` modules. Each place that shows it uses one of
three forms, chosen by what the mark is doing there:

- **The live shader**, where the mark is an event. It runs only where it is
  large enough to justify the device work and where arriving is the point:
  the Rooms opening screen, Rooms session setup, and the home page's hero.
  Running it everywhere would turn it into wallpaper.
- **The still artwork**, where the mark says whose page this is: the tab icon,
  the header and footer lockups, and the project README. The README uses the
  one still version that shows light.
- **The line drawing**, where the mark is one glyph among others: Rooms' two
  mark buttons, a card's lead mark, and the rule at the end of a page.

### Generated files

Every still form is generated from the shader, so the way to change the mark
is to change the shader.

- `zig build gen-mark` renders the shader in the pinned headless browser,
  traces that render, and rewrites all the generated files together.
- `zig build gen-mark-check` renders again and fails if any committed file no
  longer matches.
- Both steps need a browser, so they run beside `zig build check` rather than
  inside it. `zig build source-check` covers the part that needs no browser:
  it checks that the committed files share one geometry.

The generated files are:

- **`site/assets/mark.svg`**, the standard still artwork. The favicon, the
  square touch icon, the README, and the social card all use it, and the two
  CSS forms below are cut from it.
- **`site/assets/mark-lit.svg`**, the same mushroom with its lamps on. Only the
  project README uses it.
- **The mark blocks in `tokens.css`**, described below.

The still artwork is traced from the shader's own render in its settled pose.
That render is cel-shaded, with brightness in four flat tones and almost nothing
between them, so the artwork is exactly four flat fills.

### The lit version

The lamps in `mark-lit.svg` are not a fifth tone. The generator finds them by
comparing the lit render with the unlit one and keeping what the light added,
which is the only way to capture the line of light under the brim. The lamp
color is measured from the same comparison.

SVG has no emission or bloom, so the glow is drawn as passes of the lamp
shape: a wide, soft wash and a tight, bright one, under the lamps themselves.
The blurred passes are clipped to the mushroom, which makes them read as light
inside it rather than a halo around it.

### The two CSS forms

`tokens.css` carries the mark in two forms.

**Four masks.** `--mark-silhouette`, `--mark-flesh`, `--mark-shade`, and
`--mark-windows` each cover the same frame. `.icon-mark` stacks four
`.mark-piece` children in one box and paints each with its own tone. Using
masks keeps the drawing as one geometry, so a theme is just four colors and
there are never two whole drawings to keep in step.

The tones are measured from the shader in each theme. The shader keeps one
mushroom and lights it differently, so on the cream background the flesh and rim
come up warm and open. The windows stay as dark as at night, because they are
holes, not surfaces.

**Linework.** `--mark-line` is the same trace as one-color line art.

- It is for ornaments that want a drawn mark rather than a picture, such as a
  card's lead mark or the rule at the end of a page, and for controls where
  the mark is one glyph among others, such as Rooms' two mark buttons.
- In a control it paints through the mask over `currentColor`, like the
  stroked icons beside it, so it follows the control's color in every state.
- The line is the shader's rim band itself, the region between each outline
  and the flesh inside it. So it keeps the shader's varying thickness instead
  of an even stroke.
- A second band, traced from the cap rendered without its stalk, carries the
  brim across the stalk with its bend. That band is what shows the cap is in
  front.
- The windows are filled, not outlined, because these ornaments appear at
  twenty to forty pixels, where a small ring would close up.
- Both ornaments are pseudo-elements or bare spans, so a mask is the only way
  to give them the mushroom, and a mask takes its color from whatever paints
  it.

### Sizing and motion

The picture is a fifth larger than the box it is given, because the shader's
canvas is too. The four percentages on `.mark-piece` in `mark.css` keep a
lockup from shifting when the shader replaces the still mark.

The still mark's only motion is a bloom under the pointer. Light and its timing
belong to the shader. The artwork's tones are measured from the render, so they
are literal values with no theme variants. The mushroom is seen at night, and
its flesh and rim keep their night colors in both themes.

## Light and dark values

Tokens with two values use `light-dark()`:

```css
--ink: light-dark(#3a3027, #f3e6d0);
```

The dark theme, Syrup, is the default. A page is dark unless the reader has
chosen light, whatever the desktop prefers, and `data-theme="light"` is the
only switch. So each surface sets `color-scheme` under one selector,
`:root:not([data-theme="light"])`. `source-check` holds every surface to that
selector and refuses a theme decision based on `prefers-color-scheme`.

The diagram colors work differently. Their SVGs include light fallbacks, and
the stylesheet supplies only dark overrides. Giving those tokens a shared
light value would flatten colors the artwork keeps distinct.

Do not put a plain custom-property declaration before a `light-dark()`
declaration as a fallback. Browsers accept any token sequence in a custom
property, so the second declaration always wins, even where `light-dark()`
later fails.

## Making a change

- **The mark itself:** edit the shader in the
  `apps/rooms/web/ui/mark_gpu*.ts` modules, then run `zig build gen-mark` to
  regenerate the artwork, the favicon, the square icon, and the mark tokens.
- **A shared color or typeface:** edit `tokens.css`.
- **Where the still mark sits in its box, its bloom, or the wordmark:** edit
  `mark.css`.
- **The Rooms opening bloom:** edit `apps/rooms/web/ui/boot.css`.

To see the change:

- The Rooms app reads the stylesheet on each request, so a CSS change needs
  only a browser refresh. A change to `ui/*.ts` needs a server restart,
  because the bundle is built at startup.
- Rebuild the site with `zig build site`, or run `zig build docs-serve` while
  editing. Zine reloads content and templates, regenerates the CapTP example
  tabs when `site/examples/` changes, and triggers a CSS reload when
  `ui/tokens.css` or `ui/mark.css` changes.

Run `zig build source-check` before committing.
