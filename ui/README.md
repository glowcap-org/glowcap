# Shared UI assets

The documentation site and rooms app share the product palette, typefaces, and
single-color mark:

```text
tokens.css   palette, type, and mark
fonts/       IBM Plex Sans and IBM Plex Mono
```

Each surface keeps its own layout and component styles.

## What belongs here

- **Core tokens:** colors, typefaces, and the mark. Define them once in
  `tokens.css`.
- **Semantic tokens:** what a color means in one surface, such as a button or
  chat bubble. Define these in that surface from core tokens.
- **Component rules:** how a surface draws its own controls. Keep these with
  the surface.

Do not repeat a core value. Use `var(--accent)`, for example, rather than its
hex value. `zig build meta-check` catches repeated core colors, including
equivalent `rgb()` and `rgba()` forms. The rooms avatar ramp is exempt because
its ten fixed tints must support white initials; `page.css` documents that
exception.

## How the files are shared

Both consumers use symlinks:

- `site/assets/tokens.css` and `site/assets/fonts/*` point here.
- `apps/rooms/web/ui/tokens.css` and its `fonts/*` point here.

Zine only installs assets referenced by a template. Each font therefore needs
a `<link>` in `site/layouts/templates/base.shtml`; a `url()` inside
`tokens.css` is not enough. Without that link the browser silently synthesizes
the missing face because the font uses `font-display: swap`.

The rooms server exposes the linked files through an allowlist. Both surfaces
serve `tokens.css` at their root with `fonts/` beside it, so the relative font
URLs work unchanged. Each page loads `tokens.css` before its local stylesheet.

## The mark

The full-color pancake image belongs to the site homepage. `--mark-stack` is
the one-color version used by both interfaces. It is a CSS mask, so
`currentColor` controls its color and it follows the active theme without
another image.

## Light and dark values

Tokens with two values use `light-dark()`:

```css
--ink: light-dark(#3a3027, #f3e6d0);
```

Each surface sets `color-scheme` for the system preference and for its explicit
theme selector. The diagram colors are different: their SVGs include light
fallbacks, while the stylesheet supplies only dark overrides. Giving those
tokens a shared light value would flatten distinct colors in the artwork.
`meta-check` keeps the two dark-theme declarations in sync.

Do not add a plain custom-property declaration before a `light-dark()`
declaration as a compatibility fallback. Browsers accept any token sequence
when declaring a custom property, so the second declaration wins even where
`light-dark()` cannot be used later.

## Making a change

Edit `tokens.css` to change a shared color, typeface, or mark.

- The rooms app reads the stylesheet on each request, so CSS changes need only
  a browser refresh. Changes to `ui/*.ts` need a server restart because the
  bundle is built at startup.
- Rebuild the site with `zig build site`, or use `zig build docs-serve` while
  editing.

Run `zig build meta-check` before committing.
