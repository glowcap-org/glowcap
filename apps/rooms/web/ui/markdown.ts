// The browser-facing mirror of Rooms' versioned, inert Markdown projection.
// Authored text is parsed by the Rust application; this layer only decodes the
// projection and derives presentation facts from it.
import { markdownDocument } from "./application.ts";
import { hasIrcFormatting, type IrcRun, ircRuns } from "./text.ts";

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
		readonly title: string | null;
		readonly children: readonly MarkdownNode[];
	}
	| {
		readonly kind: "image";
		readonly destination: string | null;
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

export interface RichTextPart {
	readonly document: MarkdownDocument;
	readonly irc?: IrcRun;
	readonly before?: string;
	readonly after?: string;
}

function literal(text: string): MarkdownDocument {
	return { version: 1, blocks: [{ kind: "text", text }], degraded: "adapter-failed" };
}

/** Decode the application's total projection. An adapter/version fault keeps
 * the exact source readable, because presentation failure must not erase what
 * somebody said. */
export function readMarkdown(text: string): MarkdownDocument {
	try {
		const document = JSON.parse(markdownDocument(text)) as MarkdownDocument;
		return document.version === 1 && Array.isArray(document.blocks) ? document : literal(text);
	} catch {
		return literal(text);
	}
}

/** IRC toggles are an outer transport formatting vocabulary. Each stable run
 * gets its own Markdown document, so Markdown cannot open on one side of an IRC
 * state change and close under a different style. */
export function readRichText(text: string): readonly RichTextPart[] {
	if (!hasIrcFormatting(text)) return [{ document: readMarkdown(text) }];
	return ircRuns(text).map((irc) => {
		const before = irc.text.match(/^[ \t]+/)?.[0] ?? "";
		const after = irc.text.slice(before.length).match(/[ \t]+$/)?.[0] ?? "";
		const body = irc.text.slice(before.length, irc.text.length - after.length);
		return { irc, before, after, document: readMarkdown(body) };
	});
}

function nodesMention(nodes: readonly MarkdownNode[], nick: string): boolean {
	const wanted = nick.toLowerCase();
	const pending = [...nodes];
	while (pending.length > 0) {
		const node = pending.pop();
		if (node === undefined) break;
		if (node.kind === "mention" && (node.room || (wanted !== "" && node.name.toLowerCase() === wanted))) {
			return true;
		}
		if ("children" in node) pending.push(...node.children);
	}
	return false;
}

export function richTextMentions(reading: readonly RichTextPart[], nick: string): boolean {
	return reading.some(({ document }) => nodesMention(document.blocks, nick));
}

export function messageMentions(text: string, nick: string): boolean {
	return richTextMentions(readRichText(text), nick);
}
