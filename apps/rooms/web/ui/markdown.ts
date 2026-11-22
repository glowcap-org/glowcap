// The browser-facing mirror of Rooms' versioned, inert Markdown projection.
// Authored text, IRC formatting runs, and whom a line addresses are all read by
// the Rust application. This layer only decodes what it answers.
import * as z from "zod/mini";
import { applicationProjection, lineMentionsOf, richTextOf } from "./application.ts";
import { MAX_SCROLLBACK } from "./limits.ts";

export type MarkdownNode =
	| { readonly kind: "text"; readonly text: string }
	| { readonly kind: "group"; readonly children: readonly MarkdownNode[] }
	| { readonly kind: "mention"; readonly name: string; readonly room: boolean }
	| { readonly kind: "spoiler"; readonly children: readonly MarkdownNode[] }
	| { readonly kind: "paragraph"; readonly children: readonly MarkdownNode[] }
	| { readonly kind: "heading"; readonly level: number; readonly children: readonly MarkdownNode[] }
	| { readonly kind: "blockQuote"; readonly children: readonly MarkdownNode[] }
	| {
		readonly kind: "list";
		readonly ordered: boolean;
		readonly start: number | null;
		readonly children: readonly MarkdownNode[];
	}
	| { readonly kind: "listItem"; readonly checked: boolean | null; readonly children: readonly MarkdownNode[] }
	| { readonly kind: "emphasis"; readonly children: readonly MarkdownNode[] }
	| { readonly kind: "strong"; readonly children: readonly MarkdownNode[] }
	| { readonly kind: "delete"; readonly children: readonly MarkdownNode[] }
	| {
		readonly kind: "link";
		readonly destination: string;
		/** Where the link goes, when its label does not say. */
		readonly opens: string | null;
		readonly title: string | null;
		readonly children: readonly MarkdownNode[];
	}
	| {
		readonly kind: "image";
		readonly destination: string | null;
		readonly opens: string | null;
		readonly title: string | null;
		readonly alt: string;
	}
	| { readonly kind: "inlineCode"; readonly text: string }
	| { readonly kind: "codeBlock"; readonly language: string | null; readonly text: string }
	| { readonly kind: "break"; readonly hard: boolean }
	| { readonly kind: "thematicBreak" }
	| {
		readonly kind: "table";
		readonly alignments: readonly ("left" | "center" | "right" | "none")[];
		readonly children: readonly MarkdownNode[];
	}
	| { readonly kind: "tableRow"; readonly children: readonly MarkdownNode[] }
	| { readonly kind: "tableCell"; readonly children: readonly MarkdownNode[] }
	| { readonly kind: "footnoteDefinition"; readonly identifier: string; readonly children: readonly MarkdownNode[] }
	| { readonly kind: "footnoteReference"; readonly identifier: string };

export interface MarkdownDocument {
	readonly version: 1;
	readonly blocks: readonly MarkdownNode[];
	readonly degraded?: "source-too-large" | "parser-refused" | "document-too-complex" | "adapter-failed";
}

/** One stretch of a line from an IRC bridge, with the emphasis in force across
 * it. IRC carries emphasis as toggling control characters, so the application
 * splits the line by state. Colours stay the numbers the author picked, because
 * what they look like is a decision for the stylesheet. */
const IrcRunSchema = z.object({
	text: z.string(),
	bold: z.boolean(),
	italic: z.boolean(),
	underline: z.boolean(),
	strike: z.boolean(),
	mono: z.boolean(),
	fg: z.optional(z.number()),
	bg: z.optional(z.number()),
});
export type IrcRun = z.infer<typeof IrcRunSchema>;

function isMarkdownDocument(value: unknown): value is MarkdownDocument {
	return typeof value === "object" && value != null && "version" in value && value.version === 1 &&
		"blocks" in value && Array.isArray(value.blocks);
}

const RichTextSchema = z.array(z.object({
	irc: z.optional(IrcRunSchema),
	before: z.string(),
	after: z.string(),
	document: z.custom<MarkdownDocument>(isMarkdownDocument),
}));

export type RichTextPart = z.infer<typeof RichTextSchema>[number];

function literal(text: string): RichTextPart {
	return {
		before: "",
		after: "",
		document: { version: 1, blocks: [{ kind: "text", text }], degraded: "adapter-failed" },
	};
}

/** The application's total reading of one line: a part for each IRC formatting
 * run, each with its own document, so Markdown never spans a style change. A
 * line with no IRC formatting is one part. An adapter or version fault keeps
 * the exact source readable, because presentation failure must not erase what
 * somebody said. */
export function readRichText(text: string): readonly RichTextPart[] {
	const known = readings.get(text);
	if (known != null) {
		readings.delete(text);
		readings.set(text, known);
		return known;
	}
	let reading: readonly RichTextPart[];
	try {
		reading = applicationProjection(richTextOf(text), RichTextSchema, "rich text");
	} catch {
		return [literal(text)];
	}
	readings.set(text, reading);
	if (readings.size > MAX_SCROLLBACK) {
		for (const oldest of readings.keys()) {
			readings.delete(oldest);
			break;
		}
	}
	return reading;
}

/** Each parse crosses into Wasm and decodes JSON, and the parse is a pure
 * function of the text. The readings of the most recently read distinct
 * texts are kept, as many as one log holds. A line parses again on coming
 * back to a conversation only when more distinct texts than that were read in
 * between, and identical lines share one reading. A reading the adapter failed to produce is not
 * kept, because the next parse may succeed. Callers receive the shared value
 * through read-only types. */
const readings = new Map<string, readonly RichTextPart[]>();

/** Whom a line addresses: the member this reader answers to as `own`, or the
 * whole room. The application decides, with one reading for the live session
 * and for lines read from history or an archive. A reader's own line addresses
 * nobody, and the application finds the mention inside IRC formatting. */
const LineMentionsSchema = z.object({ member: z.boolean(), room: z.boolean() });
export type LineMentions = z.infer<typeof LineMentionsSchema>;

export function lineMentions(from: string, text: string, own: string): LineMentions {
	return applicationProjection(lineMentionsOf(from, text, own), LineMentionsSchema, "line mentions");
}
