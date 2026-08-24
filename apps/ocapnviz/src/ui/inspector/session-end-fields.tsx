/** Paired session-end heading and genesis editors. */

import type { CSSProperties } from "react";
import { EndpointAttribution, type SessionSide } from "../../schema/session-end.ts";
import { c } from "../tokens.ts";
import { AttributionChip } from "../EntityChips.tsx";
import { EnumSelect, Field, FieldGroup, InlineTextField, NOBODY, NONE, NOTHING, PeerSelect } from "./fields.tsx";
import type { EditorBindings } from "./bindings.ts";
import type { PickerOption } from "./picker-labels.ts";
import { inlineMonoInput, kv, valueName, valueText } from "./styles.tsx";
import { Identifier } from "../identifier.tsx";
import { type EndName as EndNameOf } from "../session-name.ts";

/** The heading's two ends and the arrow between them.
 *
 *  A row rather than a run of text, because the heading has to hold two
 *  names and one line. Left as text the first name takes the whole line
 *  and the reader loses the arrow and the second end entirely; as flex
 *  items both names give way together and the arrow, which is one
 *  character and the thing that makes the heading a pair, never does.
 *
 *  Each end is shown the way its kind of name wants. A peer's name is a
 *  name and clips at its end, because a name reads left to right. A
 *  claim nothing proved is a string the network chose, so it goes
 *  through `Identifier` and keeps both of its ends. */
const endNamesRow = {
	display: "flex",
	alignItems: "baseline",
	minWidth: 0,
} satisfies CSSProperties;

// The cap, not the shrink, is what makes this read well. Flex shrinking
// alone takes the most from the widest item, so a key on one end ate the
// short readable name on the other and left "Caro…" beside it. A ceiling
// of sixty percent means a long name is cut before it can crowd its
// partner, a short one is never cut at all, and two long ones fall back
// to shrinking, which halves them evenly.
const endNameCell = {
	flex: "0 1 auto",
	maxWidth: "60%",
	minWidth: 0,
	overflow: "hidden",
	textOverflow: "ellipsis",
	whiteSpace: "nowrap",
} satisfies CSSProperties;

function EndName({ name }: { name: EndNameOf }) {
	return name.opaque
		? <Identifier value={name.text} style={endNameCell} />
		: <span style={endNameCell}>{name.text}</span>;
}

export function SessionEndNames({ a, b }: { a: EndNameOf; b: EndNameOf }) {
	return (
		<span style={endNamesRow}>
			<EndName name={a} />
			<span
				style={{ color: c.textSubtle, paddingInline: 5, flexShrink: 0 }}
			>
				↔
			</span>
			<EndName name={b} />
		</span>
	);
}

/** One end of a session: what it claims to be, the peer it is attached
 *  to, and what attributed it.
 *
 *  The three go in a group of their own, titled with the side. A session
 *  has exactly two ends and they are symmetrical, and saying "end a" in
 *  front of all three labels was the label doing a grouping's job — six
 *  rows that looked like six unrelated facts, each with its longest word
 *  spent on something the reader already knew. With the side in the
 *  title the labels are short, which is also what leaves the value
 *  column room for a sixty-four character key.
 *
 *  In Build mode the rows edit what the end is BORN with, which is row 0
 *  of that end's trajectory. It lives here rather than in the Timing
 *  list for the reason the ends themselves do: a reader looking for what
 *  an end is looks in Details. Later moments are trajectory rows below,
 *  where the same attachment can be stated at a time instead of at
 *  birth.
 *
 *  Read-only, the peer is the one the end is attached to AT the
 *  playhead, which is the peer the stage is drawing the edge to, and
 *  the attribution beside it is that same attachment's — the two are
 *  one fact and are never read from two different moments.
 *
 *  The engine is where the one-way invariant is enforced — nothing can
 *  attribute an end to nobody — and an unattached end's attribution
 *  picker therefore says so instead of offering a write that would be
 *  refused. A control a reader can change with no effect is worse than
 *  one that is plainly unavailable: the first teaches that the model is
 *  arbitrary, and the second teaches the invariant. */
export function SessionEndFields(
	{
		sessionId,
		side,
		claim,
		peer,
		peerLabel,
		attributedBy,
		peers,
		editor,
	}: {
		sessionId: string;
		side: SessionSide;
		/** What the end claims to be, or undefined when it claims nothing. */
		claim: string | undefined;
		/** The peer id the end is attached to, or undefined for nobody. */
		peer: string | undefined;
		/** That peer's name at the playhead, for the read-only row. */
		peerLabel: string | undefined;
		attributedBy: EndpointAttribution | undefined;
		/** Every peer this end could be attached to, each with the name it
		 *  answers to at the playhead. */
		peers: readonly PickerOption[];
		editor: EditorBindings | undefined;
	},
) {
	return (
		<FieldGroup title={`End ${side.toUpperCase()}`}>
			<div style={kv}>
				<Field label="claims">
					{editor
						? (
							<InlineTextField
								value={claim ?? ""}
								onChange={(next) =>
									editor.onUpdateSessionEndpoint(
										sessionId,
										side,
										{
											designator: next,
										},
									)}
								ariaLabel={`What end ${side} claims to be`}
								editLabel="Edit end claim"
								editSession={editor}
								placeholder={NOTHING}
								style={inlineMonoInput}
							/>
						)
						: claim === undefined
						? <span style={valueText}>{NOTHING}</span>
						: <Identifier value={claim} />}
				</Field>
				<Field label="attached to">
					{editor
						? (
							<PeerSelect
								value={peer ?? NONE}
								peers={peers}
								nobody
								ariaLabel={`Peer attached to end ${side}`}
								onChange={(v) =>
									editor.onUpdateSessionEndpoint(
										sessionId,
										side,
										{
											peer: v === NONE ? null : v,
										},
									)}
							/>
						)
						: peerLabel === undefined
						? <span style={valueText}>{NOBODY}</span>
						: (
							<span style={valueName} title={peerLabel}>
								{peerLabel}
							</span>
						)}
				</Field>
				<Field label="attribution">
					{editor
						? (
							<EnumSelect
								value={attributedBy ?? NONE}
								options={[NONE, ...EndpointAttribution.options]}
								ariaLabel={`What attributed end ${side}`}
								labelFor={(v) => v === NONE ? NOTHING : v}
								disabledReason={peer === undefined
									? "Nothing can attribute an end to nobody. Attach the end to a peer first."
									: undefined}
								onChange={(v) =>
									editor.onUpdateSessionEndpoint(
										sessionId,
										side,
										{
											attributedBy: v === NONE ? null : EndpointAttribution.parse(v),
										},
									)}
							/>
						)
						: <AttributionChip attribution={attributedBy} />}
				</Field>
			</div>
		</FieldGroup>
	);
}
