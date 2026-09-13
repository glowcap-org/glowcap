// What a reader can write in a message, said where they write it.
//
// The parser is the shared Rust application and it is the one authority on
// what a line means. Nothing here restates its grammar in prose. Each example
// below is real source that Help renders through that parser and shows beside
// the source itself, so the screen that says "this is what you can write" is
// showing the reader the truth by construction, and a change to the grammar
// changes the help with it rather than stranding a description of the old one.
//
// The examples are few and ordinary on purpose. The complete grammar is
// CommonMark's with GitHub's additions and is linked; this is the page for
// somebody who wants bold and a list and did not know they could have either.

import type { LinkedText } from "./help.ts";

/** The lead links the word itself to a reference a first-time writer can use,
 * and the closing sentence names the exact grammar for a reader who wants it
 * precisely: CommonMark, with the additions GitHub made to it. */
export const writingLead: LinkedText = [
	"Messages take ",
	{ text: "Markdown", href: "https://commonmark.org/help/" },
	". Type it the way you would anywhere else, and this is what it becomes.",
];

/** One thing a reader can write: what it does, and the exact source that
 * does it. Help renders the source through the real parser beside the source. */
export interface WritingExample {
	readonly what: string;
	readonly source: string;
}

/** The two columns every example is read across. */
export const writingTypeColumn = "You type";
export const writingSeeColumn = "Everyone sees";

export const writingExamples: readonly WritingExample[] = [
	{ what: "Bold, italic, struck out", source: "**bold**, *italic*, and ~~struck out~~" },
	{ what: "Code", source: "Inline `code`, or a block of it:\n\n```\nzig build check\n```" },
	{ what: "A link", source: "[the spec](https://ocapn.org), or just https://ocapn.org" },
	{ what: "A list", source: "- one\n- two\n  - and under two\n\n1. first\n2. second" },
	{ what: "Things to do", source: "- [x] done\n- [ ] not yet" },
	{ what: "Quoting someone", source: "> what they said\n\nwhat you think" },
	{ what: "A heading", source: "## Notes from today" },
	{ what: "A table", source: "| Room | Who |\n| --- | --- |\n| lobby | everyone |" },
	{ what: "A name", source: "@alice will know. @here reaches everyone in the room." },
	{ what: "An emoji, by name", source: "Shipped it :rocket:" },
	{ what: "Hidden until pressed", source: "The ending is ||they were the same person||" },
];

export const writingMore: LinkedText = [
	"The rest works too: footnotes, reference links, nested quotes, headings of every size. Raw HTML is shown as text rather than run, and an image is a link until you choose to open it. The exact grammar is ",
	{ text: "CommonMark", href: "https://spec.commonmark.org/" },
	" with ",
	{ text: "GitHub's additions", href: "https://github.github.com/gfm/" },
	".",
];

/** One key or chord, and what it does. `mod` stands for the command key on
 * Apple hardware and Ctrl everywhere else; the component substitutes, so these
 * words do not have to know what machine they are on. */
export interface WritingShortcut {
	readonly what: string;
	readonly keys: readonly string[];
}

export const writingShortcutsTitle = "Keys";
export const writingShortcuts: readonly WritingShortcut[] = [
	{ what: "Send", keys: ["Enter"] },
	{ what: "A new line without sending", keys: ["Shift", "Enter"] },
	{ what: "Bold what is selected", keys: ["mod", "B"] },
	{ what: "Italic", keys: ["mod", "I"] },
	{ what: "Code", keys: ["mod", "E"] },
	{ what: "Struck out", keys: ["mod", "Shift", "X"] },
	{ what: "An emoji, by name", keys: [":"] },
	{ what: "A command", keys: ["/"] },
	{ what: "The last thing you sent, to edit it", keys: ["Up"] },
];

/** The line under an empty, focused field. The keys a first keystroke needs,
 * and one way to the rest; a list of every syntax there was furniture nobody
 * read and half of it ran off the end of the row. */
export interface ComposerHintItem {
	readonly key: string;
	readonly does: string;
}

export const composerHintMessage: readonly ComposerHintItem[] = [
	{ key: "Enter", does: "to send" },
	{ key: "Shift+Enter", does: "for a new line" },
	{ key: "mod+B", does: "bold" },
	{ key: "mod+I", does: "italic" },
	{ key: "/", does: "for a command" },
];
export const composerHintDirectory: readonly ComposerHintItem[] = [
	{ key: "Enter", does: "to run" },
	{ key: "/", does: "for a command, like /help" },
];
/** The way from the hint to the writing help. */
export const composerHintFormatting = "Formatting";

/** What `/help` adds after the command list. Plain words rather than a syntax
 * demonstration, because this line is itself rendered as a message and bold
 * markers here would show as bold instead of as something to type. */
export const helpCommandFormatting = "Messages take Markdown. The Writing tab of Help shows what you can write.";
