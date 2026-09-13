// What Help promises a reader can write, held to the parser that reads it.
//
// The writing help renders its examples through the real parser, which is
// what makes it true by construction. This pins the other half of that
// promise: that every example parses whole, and that each one becomes the
// structure its caption says. A caption that promised a list over source the
// parser read as a paragraph would be help teaching the wrong grammar, in the
// one place a reader is told the grammar.
//
// The formatting chords are pure functions of the text and the selection, so
// they are pinned here too, without a textarea.

import { renderToStaticMarkup } from "react-dom/server";
import { createElement } from "react";
import { RichText } from "../web/ui/panes/RichText.tsx";
import { readMarkdown } from "../web/ui/markdown.ts";
import { writingExamples } from "../lib/text/writing.ts";
import { keyLabel, markerFor, wrapSelection } from "../web/ui/composer/keys.ts";
import { assertEquals } from "./assert.ts";
import "./support/browser_application.ts";

function fail(message: string): never {
	throw new Error(message);
}

function drawn(text: string): string {
	return renderToStaticMarkup(createElement(RichText, { text, nick: "" }));
}

Deno.test("every writing example parses whole", () => {
	for (const example of writingExamples) {
		const document = readMarkdown(example.source);
		if (document.degraded !== undefined) {
			fail(`${example.what}: the parser degraded it (${document.degraded})`);
		}
	}
});

Deno.test("each example becomes the structure its caption promises", () => {
	// One mark of the promised structure per example, in the caption's own words.
	const promised: Record<string, readonly string[]> = {
		"Bold, italic, struck out": ["<strong>", "<em>"],
		"Code": ["<code>", "<pre"],
		"A link": ["<a ", "https://ocapn.org"],
		"A list": ["<ul>", "<ol"],
		"Things to do": ["markdown-task"],
		"Quoting someone": ["<blockquote>"],
		"A heading": ["markdown-heading"],
		"A table": ["<table>"],
		"A name": ["mention"],
		"An emoji, by name": ["🚀"],
		"Hidden until pressed": ["spoiler"],
	};
	assertEquals(
		Object.keys(promised).sort(),
		writingExamples.map((example) => example.what).sort(),
		"every example has a promise pinned here, and every promise names an example",
	);
	for (const example of writingExamples) {
		const html = drawn(example.source);
		for (const mark of promised[example.what]) {
			if (!html.includes(mark)) {
				fail(`${example.what}: expected ${JSON.stringify(mark)} in ${JSON.stringify(html)}`);
			}
		}
	}
});

Deno.test("a chord wraps the selection and the same chord takes it off again", () => {
	assertEquals(wrapSelection("say hello there", 4, 9, "**"), { text: "say **hello** there", start: 6, end: 11 });
	// Wrapped, with the markers just outside what is selected.
	assertEquals(wrapSelection("say **hello** there", 6, 11, "**"), { text: "say hello there", start: 4, end: 9 });
	// Wrapped, with the markers inside what is selected.
	assertEquals(wrapSelection("say **hello** there", 4, 13, "**"), { text: "say hello there", start: 4, end: 9 });
	// Nothing selected: the pair, with the caret between them.
	assertEquals(wrapSelection("say ", 4, 4, "`"), { text: "say ``", start: 5, end: 5 });
});

Deno.test("the chords are the command key with B, I, E, and Shift X", () => {
	const press = (key: string, extra: Partial<Parameters<typeof markerFor>[0]> = {}) => ({
		key,
		metaKey: false,
		ctrlKey: false,
		shiftKey: false,
		altKey: false,
		...extra,
	});
	assertEquals(markerFor(press("b", { ctrlKey: true }), false), "**");
	assertEquals(markerFor(press("i", { ctrlKey: true }), false), "*");
	assertEquals(markerFor(press("e", { ctrlKey: true }), false), "`");
	assertEquals(markerFor(press("X", { ctrlKey: true, shiftKey: true }), false), "~~");
	// On Apple hardware the command key is ⌘, and Ctrl is left to the browser.
	assertEquals(markerFor(press("b", { metaKey: true }), true), "**");
	assertEquals(markerFor(press("b", { ctrlKey: true }), true), null);
	// A plain letter, or one with Alt, is typing.
	assertEquals(markerFor(press("b"), false), null);
	assertEquals(markerFor(press("b", { ctrlKey: true, altKey: true }), false), null);
});

Deno.test("the hint spells the command key for the machine it is on", () => {
	assertEquals(keyLabel("mod+B", true), "⌘B");
	assertEquals(keyLabel("mod+B", false), "Ctrl+B");
	assertEquals(keyLabel("mod", true), "⌘");
	assertEquals(keyLabel("Enter", true), "Enter");
});
