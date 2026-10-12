// Exhaustive, injection-free rendering of the shared Rooms Markdown document.
// Rust owns grammar and link authority. Every authored value reaches React as
// a child or a checked attribute, never as HTML.
import { Fragment, type ReactNode, useId, useMemo, useState } from "react";
import { showHiddenText, taskStatus } from "../../../lib/text/controls.ts";
import { richTextImageLabel } from "../../../lib/text/page.ts";
import { type MarkdownDocument, type MarkdownNode, readRichText, type RichTextPart } from "../markdown.ts";
import { type IrcRun, substituteEmoji } from "../text.ts";

function Spoiler({ children }: { children: ReactNode }) {
	const [shown, setShown] = useState(false);
	return shown
		? <span className="spoiler shown">{children}</span>
		: (
			<button type="button" className="spoiler" aria-label={showHiddenText} onClick={() => setShown(true)}>
				{children}
			</button>
		);
}

function IrcSpan({ run, children }: { run: IrcRun; children: ReactNode }) {
	let out = children;
	if (run.mono) out = <code>{out}</code>;
	if (run.strike) out = <s>{out}</s>;
	if (run.italic) out = <em>{out}</em>;
	if (run.bold) out = <strong>{out}</strong>;
	if (run.underline) out = <u>{out}</u>;
	if (run.fg === undefined && run.bg === undefined) return <>{out}</>;
	const paint = [run.fg === undefined ? "" : `irc-fg-${run.fg}`, run.bg === undefined ? "" : `irc-bg-${run.bg}`]
		.filter(Boolean)
		.join(" ");
	return <span className={paint}>{out}</span>;
}

function footnoteId(prefix: string, identifier: string): string {
	// A fragment is percent-decoded before the browser looks up its target. Keep
	// both sides in a fragment-safe alphabet so an identifier with
	// spaces or non-ASCII text cannot point somewhere other than its definition.
	const instance = prefix.replaceAll(":", "");
	const encoded = Array.from(identifier, (character) => character.codePointAt(0)!.toString(16)).join("-");
	return `${instance}-footnote-${encoded}`;
}

function Table(
	{ node, nick, footnotes }: { node: Extract<MarkdownNode, { kind: "table" }>; nick: string; footnotes: string },
) {
	const rows = node.children.filter((child): child is Extract<MarkdownNode, { kind: "tableRow" }> =>
		child.kind === "tableRow"
	);
	const row = (cells: readonly MarkdownNode[], heading: boolean) =>
		cells.map((cell, cellAt) => {
			const cellChildren = cell.kind === "tableCell" ? cell.children : [cell];
			const alignment = node.alignments[cellAt] ?? "none";
			const Cell = heading ? "th" : "td";
			return (
				<Cell key={cellAt} className={`markdown-align-${alignment}`}>
					<MarkdownNodes nodes={cellChildren} nick={nick} footnotes={footnotes} />
				</Cell>
			);
		});
	return (
		<div className="markdown-table-scroll">
			<table>
				{rows[0] !== undefined && (
					<thead>
						<tr>{row(rows[0].children, true)}</tr>
					</thead>
				)}
				<tbody>
					{rows.slice(1).map((bodyRow, rowAt) => <tr key={rowAt}>{row(bodyRow.children, false)}</tr>)}
				</tbody>
			</table>
		</div>
	);
}

function MarkdownNodeView(
	{ node, nick, footnotes }: { node: MarkdownNode; nick: string; footnotes: string },
): ReactNode {
	const children = "children" in node
		? <MarkdownNodes nodes={node.children} nick={nick} footnotes={footnotes} />
		: null;
	switch (node.kind) {
		case "text":
			return substituteEmoji(node.text);
		case "group":
			return children;
		case "mention": {
			const you = nick !== "" && node.name.toLowerCase() === nick.toLowerCase();
			return <span className={node.room ? "mention room" : you ? "mention you" : "mention"}>@{node.name}</span>;
		}
		case "spoiler":
			return <Spoiler>{children}</Spoiler>;
		case "paragraph":
			return <p>{children}</p>;
		case "heading":
			return (
				<div className={`markdown-heading h${node.level}`} role="heading" aria-level={node.level}>
					{children}
				</div>
			);
		case "blockQuote":
			return <blockquote>{children}</blockquote>;
		case "list":
			return node.ordered ? <ol start={node.start ?? undefined}>{children}</ol> : <ul>{children}</ul>;
		case "listItem":
			return (
				<li className={node.checked === null ? undefined : "markdown-task"}>
					{node.checked !== null && (
						<input type="checkbox" checked={node.checked} disabled aria-label={taskStatus} />
					)}
					{children}
				</li>
			);
		case "emphasis":
			return <em>{children}</em>;
		case "strong":
			return <strong>{children}</strong>;
		case "delete":
			return <s>{children}</s>;
		case "link":
			return (
				<a href={node.destination} title={node.title ?? undefined} target="_blank" rel="noopener noreferrer">
					{children}
				</a>
			);
		case "image": {
			const label = richTextImageLabel(node.alt, node.destination);
			return node.destination === null ? <span className="markdown-image-link">{label}</span> : (
				<a
					className="markdown-image-link"
					href={node.destination}
					title={node.title ?? undefined}
					target="_blank"
					rel="noopener noreferrer"
				>
					{label}
				</a>
			);
		}
		case "inlineCode":
			return <code>{node.text}</code>;
		case "codeBlock":
			return (
				<pre
					className="code-block"
					data-language={node.language ?? undefined}
				><code>{node.text}</code></pre>
			);
		case "break":
			return node.hard ? <br /> : " ";
		case "thematicBreak":
			return <hr />;
		case "table":
			return <Table node={node} nick={nick} footnotes={footnotes} />;
		case "tableRow":
		case "tableCell":
			return children;
		case "footnoteDefinition":
			return (
				<div className="markdown-footnote" id={footnoteId(footnotes, node.identifier)}>
					<sup>{node.identifier}</sup>
					{children}
				</div>
			);
		case "footnoteReference":
			return (
				<sup className="markdown-footnote-ref">
					<a href={`#${footnoteId(footnotes, node.identifier)}`}>{node.identifier}</a>
				</sup>
			);
		default: {
			const exhaustive: never = node;
			return exhaustive;
		}
	}
}

function MarkdownNodes(
	{ nodes, nick, footnotes }: { nodes: readonly MarkdownNode[]; nick: string; footnotes: string },
) {
	return <>{nodes.map((node, at) => <MarkdownNodeView key={at} node={node} nick={nick} footnotes={footnotes} />)}</>;
}

function MarkdownContent(
	{ document, nick, inlineRoot = false }: { document: MarkdownDocument; nick: string; inlineRoot?: boolean },
) {
	const id = useId();
	const blocks = inlineRoot
		? document.blocks.flatMap((node) => node.kind === "paragraph" ? node.children : [node])
		: document.blocks;
	return <MarkdownNodes nodes={blocks} nick={nick} footnotes={id} />;
}

export function RichText(
	{ text, nick, reading }: { text: string; nick: string; reading?: readonly RichTextPart[] },
) {
	const parsed = useMemo(() => reading ?? readRichText(text), [reading, text]);
	return (
		<>
			{parsed.map((part, at) => {
				const content = (
					<>
						{part.before}
						<MarkdownContent document={part.document} nick={nick} inlineRoot={part.irc !== undefined} />
						{part.after}
					</>
				);
				return part.irc === undefined
					? <Fragment key={at}>{content}</Fragment>
					: <IrcSpan key={at} run={part.irc}>{content}</IrcSpan>;
			})}
		</>
	);
}
