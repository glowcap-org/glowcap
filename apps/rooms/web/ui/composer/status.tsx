// The line under the field: what the field has to say about itself.
//
// One row for four things: why the field refuses, what the draft is doing to
// the room's cap, what the keys do, and who else is typing. One row rather
// than a row each, because the composer reserves this height once and never
// moves when a line comes or goes.
//
// The row reads left to right, what is standing then what is passing. A
// standing line is true until something changes it: the session is read only,
// the conversation is closed, the draft is past the cap. A passing line is
// true only now: somebody is at their keyboard, and in a moment they are not.
// They sit beside each other rather than taking turns, so neither has to lose
// for the other to be read. That is also what makes the row honest by
// construction. Stacking them in one box and fading them in turn would make "one at a
// time" a promise kept by a stylesheet rule per pair of lines, only as
// complete as the pairs somebody thought to write: a read-only session with a
// peer typing would print both sentences through each other, and so would a
// draft past the cap. In a row there is nothing to referee.
//
// Its own component, and its own subscription to who is typing, so a peer's
// keystroke repaints this row and not the whole composer around it.

import { Fragment } from "react";
import { useTypingSaid } from "./bits.tsx";
import { keyLabel } from "./keys.ts";
import { Said } from "../Said.tsx";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useOpenModal } from "../modal.ts";
import { composerHintDirectory, composerHintFormatting, composerHintMessage } from "../../../lib/text/writing.ts";

export function ComposerStatus(
	{ unavailable, capSaid, convKey, nick, mobile, directory }: {
		/** Why the field refuses, or empty while it does not. */
		unavailable: string;
		/** What the draft is doing to the room's cap, or null while nothing. */
		capSaid: { over: boolean; said: string } | null;
		/** The conversation whose typers to name, or null with none open. */
		convKey: string | null;
		/** This reader's own name, which is never announced as typing. */
		nick: string;
		mobile: boolean;
		/** A directory conversation takes commands, so its reminder names those. */
		directory: boolean;
	},
) {
	const said = useTypingSaid(convKey, nick);
	const browser = useRoomsBrowser();
	const openModalFrom = useOpenModal();
	// Which standing line holds its end of the row. Whether the two furniture
	// lines have earned it is still the stylesheet's call, because that is a
	// question about the caret.
	//
	// The shortcut reminder is desktop furniture and stays off a phone. The
	// room's cap does not: it is the only warning that a draft will not go, it
	// carries the alert a reader is told about, and hiding it on a phone once
	// left a Send button that silently did nothing. Decided here rather than by
	// a stylesheet rule, because the caret rule that shows the hint sets
	// `display` and outranks a plain `display: none` by specificity, which is
	// how the reminder came back on phones for one commit.
	const standing: "availability" | "cap" | "hint" | null = unavailable !== ""
		? "availability"
		: capSaid !== null
		? "cap"
		: mobile
		? null
		: "hint";
	const hint = directory ? composerHintDirectory : composerHintMessage;
	return (
		<div className="composer-status">
			{
				/* Mounted even with nothing to say, which is this component's one
			    exception and why `Said` explains itself about it. */
			}
			<Said
				id="composerAvailability"
				className={standing === "availability" ? "composer-availability show" : "composer-availability"}
				kind="warning"
			>
				{unavailable}
			</Said>
			{standing === "cap" && capSaid !== null
				? (
					<div
						id="lineRoom"
						className={capSaid.over ? "hint room-cap over" : "hint room-cap"}
						role={capSaid.over ? "alert" : undefined}
					>
						{capSaid.said}
					</div>
				)
				: standing === "hint"
				? (
					<div id="hint" className="hint">
						{hint.map((item, at) => (
							<Fragment key={item.key}>
								{at > 0 && " · "}
								<b>{keyLabel(item.key)}</b> {item.does}
							</Fragment>
						))}
						{!directory && (
							<>
								{" · "}
								{
									/* The hint is up only while the field has the caret, and a
								    press would take the caret and the hint with it before the
								    press landed. Keeping the caret where it is on mousedown is
								    what lets the click arrive; the stylesheet keeps the hint up
								    while this control has focus for the keyboard's sake. */
								}
								<button
									type="button"
									id="composerFormatting"
									className="hint-link"
									onMouseDown={(event) => event.preventDefault()}
									onClick={(event) =>
										openModalFrom(event.currentTarget, () => browser.openHelp("writing"))}
								>
									{composerHintFormatting}
								</button>
							</>
						)}
					</div>
				)
				: null}
			{
				/* Last, because what is passing follows what is standing: the reader
			    keeps the reason the field is dead and still learns that somebody
			    is answering. Mounted while empty for the same reason the line
			    above it is. */
			}
			<div id="typing" className={said ? "typing show" : "typing"} aria-hidden="true">
				{said}
			</div>
		</div>
	);
}
