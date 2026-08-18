// What a directory says about itself, wherever it is being asked.
//
// The rail's caption under a room, and Settings' button for the directory that
// served this page, both open the same card. That split only works if the card
// is the one authority for the three answers a locator raises and a name cannot
// settle.
//
// The third one is the one people are surprised by. A name here is granted by
// the directory for the length of a connection and taken back when it ends, so
// the name you go by on one is not a name you own anywhere else.

import type { DirView } from "./types.ts";
import { PHASE_SAID } from "./text.ts";

/** Whether anyone can message you on this directory.
 *
 * Being reachable is a registration this directory can refuse, and a refused one
 * leaves this window in every roster looking ordinary while no direct message
 * can arrive. The name and the connection come first because both are needed
 * before the question means anything: no name, nothing to register; no
 * connection, nothing registered. */
function dmSaid(dir: DirView) {
	if (dir.nick === "") return "Not yet: no name granted here";
	if (dir.session !== "connected") return "Not while this directory is away";
	if (dir.dmUnreachable === "") return "Others can reach you here";
	return <span className="dirfact-why">{dir.dmUnreachable}</span>;
}

export function DirectoryFacts({ dir, rooms }: { dir: DirView; rooms: number }) {
	return (
		<dl className="dirfacts">
			<dt>Connection</dt>
			<dd>
				<span className={"dot " + dir.session} aria-hidden="true" />
				{PHASE_SAID[dir.session]}
				{
					/* And what it is doing, whenever it is doing something worth
					    saying. The phase alone is the one thing a reader already
					    knows — they opened this card because they wondered about
					    this directory — and the sentence saying what happened was
					    being kept for the line under the rail, which speaks for
					    whichever directory is on screen rather than for this one. A
					    reader holding two, one of them down, opened the card of the
					    broken one and was told "Not connected".

					    It is said here at every phase, because the net layer writes
					    these for a healthy session too — reaching a locator,
					    entering a room — and this card is the one surface that is
					    about this directory rather than about the reader. */
				}
				{dir.statusText !== "" && dir.statusText !== PHASE_SAID[dir.session].toLowerCase() && (
					<span className="dirfact-why">{dir.statusText}</span>
				)}
			</dd>
			<dt>Your name here</dt>
			<dd>{dir.nick === "" ? "Not granted yet" : dir.nick}</dd>
			{
				/* Whether anyone can message you here, which is the next question a
				    granted name raises and the one nothing used to answer. Being
				    reachable is a registration this directory can refuse, and a
				    refused one leaves this window in every roster looking ordinary
				    while no direct message can arrive. */
			}
			<dt>Direct messages</dt>
			<dd>{dmSaid(dir)}</dd>
			<dt>Rooms you are in</dt>
			<dd>{rooms === 0 ? "None" : rooms === 1 ? "1 room" : rooms + " rooms"}</dd>
		</dl>
	);
}

/** Said wherever a granted name is shown, so the one thing about directories
 * that surprises people is not explained twice in two wordings that can drift
 * apart. */
export function GrantedNameNote() {
	return (
		<p className="hint">
			A directory grants your name for as long as you are connected and takes it back when you are not, so it is
			not a name you hold anywhere else.
		</p>
	);
}
