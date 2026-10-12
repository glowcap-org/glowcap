// What a message line becomes, held where it is decidable without a browser.
//
// The renderer is one pattern with an alternative per kind of span, read by
// position: adding a kind renumbers every arm after it, and getting that wrong
// swaps bold for strikethrough or turns a link into a mention. Nothing about
// that is visible in a type, and the browser proof drives only a couple of the
// kinds. The arms are pinned here, one line each, so a renumbering becomes a
// row of failures rather than one odd bubble
// somebody notices a week later.
//
// React's own static renderer supplies the hook dispatcher and answers with the
// actual elements. Calling a function component by hand is not rendering: it
// breaks as soon as that component owns state, and accepting the resulting
// invalid-hook warning as a test result would hide a real renderer misuse.

import { renderToStaticMarkup } from "react-dom/server";
import { createElement } from "react";
import { RichText } from "../web/ui/panes/RichText.tsx";
import { assertEquals } from "./assert.ts";
import { hasIrcFormatting } from "../web/ui/text.ts";
import { messageMentions } from "../web/ui/markdown.ts";
import "./support/browser_application.ts";

function fail(message: string): never {
	throw new Error(message);
}

function drawn(text: string, nick = "zoe"): string {
	return renderToStaticMarkup(createElement(RichText, { text, nick }));
}

function paragraph(inner: string): string {
	return `<p>${inner}</p>`;
}

function includes(output: string, wanted: string): void {
	if (!output.includes(wanted)) fail(`expected ${JSON.stringify(output)} to include ${JSON.stringify(wanted)}`);
}

Deno.test("each inline kind becomes its own element", () => {
	assertEquals(drawn("`code`"), paragraph("<code>code</code>"), "code");
	assertEquals(drawn("**bold**"), paragraph("<strong>bold</strong>"), "bold");
	assertEquals(drawn("~~gone~~"), paragraph("<s>gone</s>"), "strikethrough");
	assertEquals(drawn("*soft*"), paragraph("<em>soft</em>"), "asterisk emphasis");
	assertEquals(drawn("_soft_"), paragraph("<em>soft</em>"), "underscore emphasis");
	assertEquals(
		drawn("https://example.com"),
		paragraph('<a href="https://example.com" target="_blank" rel="noopener noreferrer">https://example.com</a>'),
		"link",
	);
});

Deno.test("a link keeps the punctuation that ends the sentence", () => {
	// The full stop belongs to the writer, not to the address.
	assertEquals(
		drawn("see https://example.com."),
		paragraph(
			'see <a href="https://example.com" target="_blank" rel="noopener noreferrer">https://example.com</a>.',
		),
	);
});

Deno.test("a spoiler is a control until it is asked", () => {
	// Covered it is pressable, so it can be asked by keyboard and on
	// a phone; the text is in the document either way so opening one does not
	// resize the message and give itself away.
	assertEquals(
		drawn("||**secret**||"),
		paragraph(
			'<button type="button" class="spoiler" aria-label="Show hidden text"><strong>secret</strong></button>',
		),
	);
	assertEquals(
		drawn("unclosed ||secret"),
		paragraph("unclosed ||secret"),
		"an unmatched delimiter stays authored text",
	);
});

Deno.test("mentions read three ways", () => {
	assertEquals(drawn("@alice"), paragraph('<span class="mention">@alice</span>'), "somebody else");
	assertEquals(drawn("@zoe"), paragraph('<span class="mention you">@zoe</span>'), "you");
	assertEquals(drawn("@here"), paragraph('<span class="mention room">@here</span>'), "the whole room");
});

Deno.test("quoted lines join into one quote", () => {
	assertEquals(drawn("> one\n> two"), "<blockquote><p>one two</p></blockquote>");
	// CommonMark permits the unmarked line as a lazy continuation of the quote.
	assertEquals(drawn("> quoted\nplain"), "<blockquote><p>quoted plain</p></blockquote>");
	// A line that merely contains a chevron is not a quote: only one that opens
	// with it is. A reader typing `a > b` means the literal comparison.
	assertEquals(drawn("a > b"), paragraph("a &gt; b"));
});

Deno.test("CommonMark nesting and GFM blocks retain their structure", () => {
	const out = drawn("## Plan\n\n1. **ship**\n   - [x] test\n\n| left | right |\n| :--- | ---: |\n| one | two |");
	includes(out, 'class="markdown-heading h2" role="heading" aria-level="2"');
	includes(out, '<ol start="1"><li><p><strong>ship</strong></p><ul>');
	includes(out, '<li class="markdown-task"><input type="checkbox"');
	includes(out, 'aria-label="Task status" checked=""');
	includes(out, '<div class="markdown-table-scroll"><table><thead>');
	includes(out, '<th class="markdown-align-left">left</th>');
	includes(out, '<td class="markdown-align-right">two</td>');
});

Deno.test("references and footnotes resolve without browser-owned grammar", () => {
	const out = drawn(
		"Read [the guide][guide]. Note[^why].\n\n[guide]: https://example.com/guide\n[^why]: Kept with the message.",
	);
	includes(out, 'href="https://example.com/guide"');
	includes(out, 'class="markdown-footnote-ref"');
	includes(out, 'class="markdown-footnote"');
});

Deno.test("raw HTML, active schemes, and remote images stay inert", () => {
	const source =
		'<img src=x data-owner="@zoe" onerror=alert(1)> [run](javascript:alert(1)) ![map](https://example.com/map.png)';
	const out = drawn(source);
	includes(out, "&lt;img src=x data-owner=&quot;@zoe&quot; onerror=alert(1)&gt;");
	if (out.includes('href="javascript:')) fail(`an active scheme gained link authority: ${out}`);
	if (out.includes("<img")) fail(`Markdown fetched a remote image: ${out}`);
	includes(out, 'class="markdown-image-link" href="https://example.com/map.png"');
	if (messageMentions(source, "zoe")) fail("literal HTML acquired mention effects");
});

Deno.test("code is excluded from mention effects", () => {
	if (messageMentions("`@zoe`", "zoe")) fail("inline code triggered a mention");
	if (messageMentions("```\n@zoe\n```", "zoe")) fail("a code block triggered a mention");
	if (messageMentions("zoe@example.com", "example")) fail("an email address triggered a mention");
	if (!messageMentions("hello @zoe", "zoe")) fail("ordinary prose lost its mention");
});

Deno.test("a fence is source, and nothing inside it is read as anything else", () => {
	// The one rule the fence exists for: rich text stops at its edge, so a code
	// block containing what looks like markup shows what was typed.
	const out = drawn("```\n**not bold** :rocket: @zoe\n```");
	assertEquals(out, '<pre class="code-block"><code>**not bold** :rocket: @zoe</code></pre>');
	if (out.includes("<strong>")) fail("markup inside a fence was rendered rather than shown");
});

// ── What arrives from an IRC bridge ────────────────────────────────────────
// IRC carries emphasis as control characters that toggle rather than delimit,
// so these are read by state: a byte turns bold on and the same byte turns it
// off, a reset clears everything, and a line may end with one still on. Written
// as escapes here because they are invisible in a file, which is exactly why a
// line carrying them could be shown with holes in it.

Deno.test("a toggle opens and closes, and reads as the app's own emphasis", () => {
	assertEquals(drawn("\x02bold\x02 after"), "<strong>bold</strong> after");
	assertEquals(drawn("\x1ditalic\x1d"), "<em>italic</em>");
	assertEquals(drawn("\x1funder\x1f"), "<u>under</u>");
	assertEquals(drawn("\x1egone\x1e"), "<s>gone</s>");
	assertEquals(drawn("\x11code\x11"), "<code>code</code>");
});

Deno.test("a toggle left on runs to the end of the line", () => {
	// IRC does not require closing one, and a client that dropped the rest of a
	// line for want of a closing byte would be losing what was said.
	assertEquals(drawn("\x02never closed"), "<strong>never closed</strong>");
});

Deno.test("emphasis nests by state rather than by pairing", () => {
	// Which is the whole difference from the marks a person types: these overlap
	// freely, and closing one leaves the others alone.
	assertEquals(drawn("\x02\x1dboth\x02still italic"), "<strong><em>both</em></strong><em>still italic</em>");
});

Deno.test("a reset clears everything at once", () => {
	const out = drawn("\x02\x1f\x1dall\x0fplain");
	// Which emphasis wraps which is arbitrary, all three are in force over the
	// same text, so this asks that each one is there and that the reset ended
	// them, rather than pinning an order that means nothing.
	for (const wrapper of ["<strong>", "<em>", "<u>"]) {
		if (!out.includes(wrapper)) fail(`${wrapper} was not in force before the reset: ${out}`);
	}
	if (!out.endsWith("plain")) fail(`the reset did not end the emphasis: ${out}`);
	if (out.includes("plain</")) fail(`the reset left emphasis running over what followed it: ${out}`);
});

Deno.test("colour is kept as the number the author picked", () => {
	// Four is red in every IRC client since the nineties. The number is carried
	// to a class so the stylesheet says what it looks like, the way every other
	// colour here works.
	assertEquals(drawn("\x034red\x03 plain"), '<span class="irc-fg-4">red</span> plain');
	assertEquals(drawn("\x034,1on black\x03"), '<span class="irc-fg-4 irc-bg-1">on black</span>');
});

Deno.test("a bridged line still reads as this app's own text", () => {
	// Both vocabularies at once: the bridge's bold, and a mention this app knows.
	assertEquals(drawn("\x02hey\x02 @zoe"), '<strong>hey</strong> <span class="mention you">@zoe</span>');
});

Deno.test("a line with no control characters takes the ordinary path untouched", () => {
	// The reading above must cost nothing for the messages this app writes, which
	// is all of them today.
	assertEquals(hasIrcFormatting("**bold** @zoe"), false);
	assertEquals(hasIrcFormatting("\x02bold"), true);
});
