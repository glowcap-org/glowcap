#!/usr/bin/env python3
"""Normalize the rendered site tree into the shape serving needs.

Two duties, both about what the server and its clients actually receive:

Page bytes: the pinned renderer serializes three shapes the HTML parser
repairs on load — a figure wrapped in the paragraph that carried its markdown
line, a captioned figure image with no alt attribute (the caption is the
description, so the image itself is decorative), and tables whose header and
body rows sit bare inside the table. This pass rewrites the served bytes into
the repaired form, so a no-script reader, a validator, and the browser all
see one document. Each transform asserts its opening and closing counts agree
per file, so a renderer whose emission changes shape fails loudly instead of
shipping a half-rewritten page.

Rooms captures are authored as adjacent dark and light Markdown images so Zine
can discover and install both assets. The page's theme is a `data-theme` stamp
rather than the desktop preference, so the choice between the two faces stays
in CSS (`site/assets/prose.css`); a `picture` keyed on `prefers-color-scheme`
would show the wrong face. This pass only holds each pair adjacent under one
caption, marks both images lazy, and writes the WebP dimensions into their
attributes: a hidden lazy image is never fetched, and the shown one reserves
its space before it arrives.

Serving shape: GitHub Pages answers a missing path with the artifact's
top-level `404.html`, so the rendered `404/index.html` is copied there;
`robots.txt` and `sitemap.xml` are written from the walked pages, with the
canonical base read from `site/zine.ziggy` so the URL has one authority,
and each destination's social-preview address and image ride the same base.

Readers that are programs: every authored page also gets an `index.md`
beside its `index.html`, converted from the page's SuperMD source, and the
root gets `llms.txt` and `llms-full.txt` in the shape https://llmstxt.org/
describes: an H1, a blockquote summary, then sections of links to those
markdown twins with each page's own description. The conversion knows the
SuperMD forms the pages use for page and section links, images, explicit
section ids, and HTML fences. It refuses a page that uses an unknown form, so
a new template expression cannot ship as a dead `$` in the markdown.

Called by `zig build site`. Direct usage is site_normalize.py <site-root>.
The reference/api tree is the generated autodoc viewer, owned by its own
fix-up, and is skipped for page-byte normalization.
"""

import re
import sys
from html.parser import HTMLParser
from pathlib import Path

HEADER_ROW = re.compile(r"<table><tr>((?:<th>.*?</th>)+)</tr>")
THEME_FIGURES = re.compile(
    r'<figure><img alt="" src="(?P<dark>[^" ]*/rooms-(?P<stem>[^" ]+)-dark\.webp)">\n?'
    r"<figcaption>(?P<caption>.*?)</figcaption></figure>"
    r'<figure><img alt="" src="(?P<light>[^" ]*/rooms-(?P=stem)-light\.webp)">\n?'
    r"<figcaption>(?P=caption)</figcaption></figure>",
    re.DOTALL,
)


def webpDimensions(path: Path) -> tuple[int, int]:
    """Read the dimensions from a WebP container without an image dependency."""
    data = path.read_bytes()
    if len(data) < 20 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise SystemExit(f"site_normalize: {path}: expected a WebP RIFF container")
    offset = 12
    while offset + 8 <= len(data):
        kind = data[offset : offset + 4]
        size = int.from_bytes(data[offset + 4 : offset + 8], "little")
        payload = data[offset + 8 : offset + 8 + size]
        if kind == b"VP8 " and len(payload) >= 10 and payload[3:6] == b"\x9d\x01\x2a":
            return (
                int.from_bytes(payload[6:8], "little") & 0x3FFF,
                int.from_bytes(payload[8:10], "little") & 0x3FFF,
            )
        if kind == b"VP8L" and len(payload) >= 5 and payload[0] == 0x2F:
            return (
                1 + payload[1] + ((payload[2] & 0x3F) << 8),
                1 + (payload[2] >> 6) + (payload[3] << 2) + ((payload[4] & 0x0F) << 10),
            )
        if kind == b"VP8X" and len(payload) >= 10:
            return (
                1 + int.from_bytes(payload[4:7], "little"),
                1 + int.from_bytes(payload[7:10], "little"),
            )
        offset += 8 + size + (size & 1)
    raise SystemExit(f"site_normalize: {path}: no supported WebP image chunk")


def normalize(text: str, path: Path, root: Path) -> str:
    opened_figures = text.count("<p><figure")
    closed_figures = text.count("</figure></p>")
    if opened_figures != closed_figures:
        raise SystemExit(
            f"site_normalize: {path}: {opened_figures} '<p><figure' but "
            f"{closed_figures} '</figure></p>'; the renderer changed shape"
        )
    text = text.replace("<p><figure", "<figure").replace("</figure></p>", "</figure>")

    text = text.replace("<figure><img src=", '<figure><img alt="" src=')

    def themeFigures(match: re.Match[str]) -> str:
        dark = match.group("dark")
        light = match.group("light")
        dark_size = webpDimensions(root / dark.rsplit("/", 1)[-1])
        light_size = webpDimensions(root / light.rsplit("/", 1)[-1])
        if dark_size != light_size:
            raise SystemExit(
                f"site_normalize: {path}: theme pair {dark!r} and {light!r} "
                f"has different dimensions, {dark_size} and {light_size}"
            )
        width, height = dark_size
        caption = match.group("caption")
        return "".join(
            f'<figure><img alt="" src="{src}" width="{width}" height="{height}" loading="lazy">\n'
            f"<figcaption>{caption}</figcaption></figure>"
            for src in (dark, light)
        )

    dark_captures = len(re.findall(r'/rooms-[^" ]+-dark\.webp', text))
    light_captures = len(re.findall(r'/rooms-[^" ]+-light\.webp', text))
    text, theme_pairs = THEME_FIGURES.subn(themeFigures, text)
    if dark_captures != light_captures or theme_pairs != dark_captures:
        raise SystemExit(
            f"site_normalize: {path}: found {dark_captures} dark and "
            f"{light_captures} light Rooms captures, but sized {theme_pairs} pairs; "
            "keep each matching pair adjacent with one caption"
        )

    # A wide listing scrolls, and a scroll region reaches keyboard users only
    # if it can take focus. The page script also sets this, but the served
    # bytes should not need the script for it.
    text = re.sub(r"<pre(?![^>]*tabindex)", '<pre tabindex="0"', text)

    text, headed = HEADER_ROW.subn(r"<table><thead><tr>\1</tr></thead><tbody>", text)
    bare_tables = text.count("<table><tr>")
    text = text.replace("<table><tr>", "<table><tbody><tr>")
    closes = text.count("</tr></table>")
    if headed + bare_tables != closes:
        raise SystemExit(
            f"site_normalize: {path}: opened {headed + bare_tables} table bodies "
            f"but found {closes} '</tr></table>' closes; the renderer changed shape"
        )
    text = text.replace("</tr></table>", "</tr></tbody></table>")
    return bindWidows(text)


# A widow is a block's last line holding one word. CSS `text-wrap: pretty`
# avoids most of them, but it is a best-effort hint, and `balance` still splits
# a three-word heading two and one. So this pass keeps each block's last two
# words together, the typesetter's fix, which holds at every width.
#
# Body text binds them with a no-break space, capped so the pair always fits a
# 320px phone column (a table scrolls inside itself, so its cells share the
# cap). A heading is set large, so a pair that fits at one width can overflow
# at another. A heading's pair goes in an inline block instead, which stays
# whole when it fits and wraps inside itself when it does not. A pair split
# across markup in a heading is left alone. `site_render.ts` measures what is
# left at every width it renders.
WIDOW_BODY = {"p", "li", "dd", "dt", "figcaption", "summary", "caption", "blockquote", "td", "th"}
WIDOW_HEADINGS = {"h1", "h2", "h3", "h4", "h5", "h6"}
WIDOW_PAIR_LIMIT = 26
# A two-word table cell reads whole or splits evenly, and binding it would
# only widen its column.
WIDOW_MIN_WORDS = {"td": 3, "th": 3}
# Text the reader may copy keeps its ordinary spaces, and raw text is not prose.
WIDOW_SKIP = {"pre", "code", "kbd", "samp", "script", "style", "svg", "math", "textarea"}


class WidowBinder(HTMLParser):
    """Find each block's last two words and how to keep them together."""

    def __init__(self, text: str) -> None:
        super().__init__(convert_charrefs=False)
        self.text = text
        self.line_starts = [0]
        for line in text.splitlines(keepends=True):
            self.line_starts.append(self.line_starts[-1] + len(line))
        self.blocks: list[dict] = []
        self.skip = 0
        self.events = 0
        # (start, end, replacement), applied from the end of the page back.
        self.edits: list[tuple[int, int, str]] = []

    def position(self) -> int:
        line, column = self.getpos()
        return self.line_starts[line - 1] + column

    def begin(self, tag: str) -> None:
        self.blocks.append({"tag": tag, "words": [], "gap": None, "gaps": []})

    def finish(self) -> None:
        block = self.blocks[-1]
        tag, words, gaps = block["tag"], block["words"], block["gaps"]
        if len(words) >= max(2, WIDOW_MIN_WORDS.get(tag, 2)) and gaps and gaps[-1][2] == len(words) - 1:
            before, last = words[-2], words[-1]
            start, end, _ = gaps[-1]
            if tag in WIDOW_HEADINGS:
                if before["event"] == last["end_event"]:
                    pair = self.text[before["start"]:last["end"]]
                    self.edits.append((before["start"], last["end"], f'<span class="keep">{pair}</span>'))
            elif before["chars"] + 1 + last["chars"] <= WIDOW_PAIR_LIMIT:
                self.edits.append((start, end, "&nbsp;"))
        block.update(words=[], gaps=[])

    def handle_starttag(self, tag: str, attrs: list) -> None:
        self.events += 1
        if tag in WIDOW_SKIP:
            self.skip += 1
        elif tag in WIDOW_BODY or tag in WIDOW_HEADINGS:
            if self.blocks:
                self.finish()
            self.begin(tag)
        elif tag == "br" and self.blocks:
            self.finish()

    def handle_endtag(self, tag: str) -> None:
        self.events += 1
        if tag in WIDOW_SKIP:
            self.skip = max(0, self.skip - 1)
        elif (tag in WIDOW_BODY or tag in WIDOW_HEADINGS) and self.blocks and self.blocks[-1]["tag"] == tag:
            self.finish()
            self.blocks.pop()

    def visible(self, start: int, end: int, chars: int) -> None:
        block = self.blocks[-1]
        words = block["words"]
        joined = words and not block["gaps"] or words and block["gaps"][-1][2] < len(words)
        if words and joined:
            words[-1].update(end=end, end_event=self.events, chars=words[-1]["chars"] + chars)
        else:
            words.append({"start": start, "end": end, "event": self.events,
                          "end_event": self.events, "chars": chars})

    def handle_data(self, data: str) -> None:
        self.events += 1
        if not self.blocks:
            return
        block = self.blocks[-1]
        base = self.position()
        for match in re.finditer(r"\s+|\S+", data):
            if not match[0].isspace():
                self.visible(base + match.start(), base + match.end(), len(match[0]))
            elif block["words"] and not self.skip:
                block["gaps"].append((base + match.start(), base + match.end(), len(block["words"])))

    def handle_entityref(self, name: str) -> None:
        self.events += 1
        if self.blocks:
            at = self.position()
            self.visible(at, at + len(name) + 2, 1)

    def handle_charref(self, name: str) -> None:
        self.events += 1
        if self.blocks:
            at = self.position()
            self.visible(at, at + len(name) + 3, 1)


def bindWidows(text: str) -> str:
    binder = WidowBinder(text)
    binder.feed(text)
    binder.close()
    for start, end, replacement in sorted(binder.edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text


def siteConfig(repo_root: Path) -> tuple[str, str]:
    """The site's name and its deployed base (origin and prefix), read from
    the site config that owns both."""
    config = (repo_root / "site" / "zine.ziggy").read_text(encoding="utf-8")
    title = re.search(r'\.title\s*=\s*"([^"]+)"', config)
    host = re.search(r'\.host_url\s*=\s*"([^"]+)"', config)
    prefix = re.search(r'\.url_path_prefix\s*=\s*"([^"]+)"', config)
    if title is None or host is None or prefix is None:
        raise SystemExit("site_normalize: site/zine.ziggy no longer names title, host_url, and url_path_prefix")
    return title.group(1), f"{host.group(1)}/{prefix.group(1)}"


FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
HTML_FENCE = re.compile(r"^```=html\n(.*?)\n```$", re.DOTALL | re.MULTILINE)
# A styled block is a blockquote whose first line names its class. Without
# that line the code tabs are one labeled code fence per language, which is
# what a markdown reader wants anyway. A link grid is a plain list, so its
# quote markers go too.
CODE_TABS = re.compile(r"^> \[\]\(\$block\.attrs\('code-tabs'\)\)\n", re.MULTILINE)
LINK_GRID = re.compile(r"^> \[\]\(\$block\.attrs\('link-grid'\)\)\n((?:> .*\n)+)", re.MULTILINE)
IMAGE_REF = re.compile(r"\[([^\]]*)\]\(\$image\.siteAsset\('([^']+)'\)\)")
THEME_IMAGE_PAIR = re.compile(
    r"\[(?P<caption>[^\]]+)\]\(\$image\.siteAsset\('(?P<stem>rooms-[^']+)-dark\.webp'\)\)\n\n"
    r"\[(?P=caption)\]\(\$image\.siteAsset\('(?P=stem)-light\.webp'\)\)"
)
PAGE_REF = re.compile(r"\(\$link\.page\('([^']+)'\)(?:\.ref\('([^']+)'\))?\)")
LOCAL_REF = re.compile(r"\(\$link\.ref\('([^']+)'\)\)")
SECTION_HEADING = re.compile(
    r"^(#{1,6}) \[([^\]]+)\]\(\$section\.id\('([^']+)'\)\)$", re.MULTILINE
)
LEFTOVER = re.compile(r"\]\(\$")


def frontmatterField(header: str, name: str, path: Path) -> str:
    found = re.search(rf'^\.{name} = "((?:[^"\\]|\\.)*)"', header, re.MULTILINE)
    if found is None:
        raise SystemExit(f"site_normalize: {path}: frontmatter names no .{name}")
    return found.group(1).replace('\\"', '"')


def pageSource(content: Path, rel: str) -> Path:
    """The SuperMD page a rendered directory came from: `x/index.smd` or `x.smd`."""
    stem = rel.rstrip("/")
    if stem == "":
        return content / "index.smd"
    for candidate in (content / stem / "index.smd", content / f"{stem}.smd"):
        if candidate.exists():
            return candidate
    raise SystemExit(f"site_normalize: no SuperMD source found for the rendered page {rel!r}")


def toMarkdown(source: Path, base: str) -> tuple[str, str, str]:
    """A page as plain Markdown: its title, its description, and its body
    with every site reference resolved to the deployed address."""
    text = source.read_text(encoding="utf-8")
    header = FRONTMATTER.match(text)
    if header is None:
        raise SystemExit(f"site_normalize: {source}: no frontmatter")
    title = frontmatterField(header.group(1), "title", source)
    description = frontmatterField(header.group(1), "description", source)
    body = text[header.end():]
    dark_captures = len(re.findall(r"\$image\.siteAsset\('rooms-[^']+-dark\.webp'\)", body))
    light_captures = len(re.findall(r"\$image\.siteAsset\('rooms-[^']+-light\.webp'\)", body))
    body, theme_images = THEME_IMAGE_PAIR.subn(
        lambda m: f"[{m.group('caption')}]($image.siteAsset('{m.group('stem')}-dark.webp'))",
        body,
    )
    if dark_captures != light_captures or theme_images != dark_captures:
        raise SystemExit(
            f"site_normalize: {source}: found {dark_captures} dark and "
            f"{light_captures} light Rooms captures, but formed {theme_images} Markdown images; "
            "keep each matching pair adjacent with one caption"
        )
    body = IMAGE_REF.sub(lambda m: f"![{m.group(1)}]({base}/{m.group(2)})", body)
    body = PAGE_REF.sub(
        lambda m: f"({base}/{m.group(1)}/{'#' + m.group(2) if m.group(2) else ''})", body
    )
    body = LOCAL_REF.sub(lambda m: f"(#{m.group(1)})", body)
    body = SECTION_HEADING.sub(
        lambda m: f'<a id="{m.group(3)}"></a>\n{m.group(1)} {m.group(2)}', body
    )
    body = HTML_FENCE.sub(lambda m: m.group(1), body)
    body = CODE_TABS.sub("", body)
    body = LINK_GRID.sub(lambda m: re.sub(r"^> ", "", m.group(1), flags=re.MULTILINE), body)
    leftover = LEFTOVER.search(body)
    if leftover is not None:
        line = body.count("\n", 0, leftover.start()) + 1
        raise SystemExit(
            f"site_normalize: {source}:{line}: a SuperMD expression this converter "
            "does not know; teach toMarkdown the form or the markdown ships it dead"
        )
    markdown = f"# {title}\n\n> {description}\n\n{body.strip()}\n"
    return title, description, markdown


def llmsSection(rel: str) -> str:
    """Which llms.txt section a page belongs to, by the tree it lives in."""
    head = rel.split("/", 1)[0]
    return {"rooms": "Rooms", "bindings": "Bindings", "transports": "Transports"}.get(head, "Pages")


def writeLlms(root: Path, name: str, base: str, listed: list[str], content: Path) -> int:
    """Write every page's markdown twin, `llms.txt`, and `llms-full.txt`."""
    sections: dict[str, list[str]] = {"Pages": [], "Rooms": [], "Bindings": [], "Transports": []}
    full: list[str] = []
    home = toMarkdown(pageSource(content, ""), base)
    # The section indexes lead their sections, and the home page leads the
    # whole file as its summary rather than as a link to itself.
    for rel in sorted(listed, key=lambda r: (llmsSection(r), r.count("/"), r)):
        title, description, markdown = toMarkdown(pageSource(content, rel), base)
        (root / rel / "index.md").write_text(markdown, encoding="utf-8")
        full.append(markdown)
        if rel == "":
            continue
        sections[llmsSection(rel)].append(f"- [{title}]({base}/{rel}index.md): {description}")
    # The H1 is the project's name, as https://llmstxt.org/ asks, and the
    # blockquote is the home page's own one-sentence description.
    lines = [f"# {name}", "", f"> {home[1]}", ""]
    for name, entries in sections.items():
        if not entries:
            continue
        lines += [f"## {name}", "", *entries, ""]
    lines += [
        "## Optional",
        "",
        f"- [API reference]({base}/reference/api/): the generated Zig autodoc, HTML only.",
        f"- [Everything above in one file]({base}/llms-full.txt)",
        "",
    ]
    (root / "llms.txt").write_text("\n".join(lines), encoding="utf-8")
    (root / "llms-full.txt").write_text("\n\n---\n\n".join(full) + "\n", encoding="utf-8")
    return len(full)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: site_normalize.py <site-root>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    name, base = siteConfig(Path(__file__).resolve().parents[2])
    pages = 0
    listed: list[str] = []
    for page in sorted(root.rglob("index.html")):
        rel = str(page.relative_to(root))
        if "reference/api" not in rel:
            original = page.read_text(encoding="utf-8")
            rewritten = normalize(original, page, root)
            # Every real destination names its one address, so a crawler that
            # reached a variant (the 404 copy, a mirrored path) still indexes
            # the destination itself. The not-found page is no destination.
            if rel != "404/index.html" and '<link rel="canonical"' not in rewritten:
                head_close = "</head>"
                if rewritten.count(head_close) != 1:
                    raise SystemExit(f"site_normalize: {page}: expected one </head>")
                loc = rel.removesuffix("index.html")
                # The link-preview card needs what only the deployed origin
                # can say: the page's one absolute address and an absolute
                # image URL, so a link pasted into a chat shows the mark
                # instead of a bare domain. The image is the touch icon,
                # which the template already names, because Zine installs an
                # asset only where a template asks for it and this URL is a
                # plain string the build cannot see.
                social = ""
                if 'property="og:url"' not in rewritten:
                    social += f'<meta property="og:url" content="{base}/{loc}">'
                if 'property="og:image"' not in rewritten:
                    social += (
                        f'<meta property="og:image" content="{base}/glowcap-icon-256.png">'
                        '<meta property="og:image:alt" content="The glowcap mark.">'
                    )
                rewritten = rewritten.replace(
                    head_close,
                    f'<link rel="canonical" href="{base}/{loc}">{social}{head_close}',
                )
            if rewritten != original:
                page.write_text(rewritten, encoding="utf-8")
            pages += 1
        # The sitemap lists real destinations: not the not-found page, and not
        # the autodoc viewer's internal frame.
        if rel != "404/index.html" and "reference/api" not in rel:
            listed.append(rel.removesuffix("index.html"))
    if pages < 20:
        print(
            f"site_normalize: only {pages} pages under {root}; a real site build "
            "has more, refusing a vacuous pass",
            file=sys.stderr,
        )
        return 1

    not_found = root / "404" / "index.html"
    if not not_found.exists():
        print("site_normalize: the rendered tree has no 404 page", file=sys.stderr)
        return 1
    (root / "404.html").write_text(not_found.read_text(encoding="utf-8"), encoding="utf-8")

    (root / "robots.txt").write_text(
        f"User-agent: *\nAllow: /\nSitemap: {base}/sitemap.xml\n", encoding="utf-8"
    )
    urls = "\n".join(
        f"  <url><loc>{base}/{rel}</loc></url>" for rel in listed
    )
    (root / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        f"{urls}\n</urlset>\n",
        encoding="utf-8",
    )
    # The autodoc viewer has no SuperMD source and no markdown twin; it is
    # linked from llms.txt as HTML under Optional.
    authored = [rel for rel in listed if not rel.startswith("reference/api")]
    twins = writeLlms(root, name, base, authored, Path(__file__).resolve().parents[2] / "site" / "content")
    print(
        f"site_normalize: {pages} pages normalized, {len(listed)} in the sitemap, "
        f"{twins} markdown twins behind llms.txt"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
