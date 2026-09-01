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
import { dirConnection, directoryDmBlocked } from "./text.ts";

/** Whether anyone can message you on this directory.
 *
 * Being reachable is a registration this directory can refuse, and a refused one
 * leaves this window in every roster looking ordinary while no direct message
 * can arrive. The name and the connection come first because both are needed
 * before the question means anything: no name, nothing to register; no
 * connection, nothing registered.
 *
 * The person card asks this too, about the reader on the directory it is
 * reading them through. One answer, because two would drift and the drift would
 * be a card telling somebody they are reachable while the directory is not
 * connected. */
export function dmSaid(dir: DirView) {
	if (dir.nick === "") return "Not yet: no name granted here";
	if (dir.session !== "connected") return directoryDmBlocked(dir.session);
	if (dir.dmUnreachable === "") return "Others can reach you here";
	return <span className="dirfact-why">{dir.dmUnreachable}</span>;
}

export function grantedNameSaid(dir: Pick<DirView, "nick"> | null): string {
	if (dir == null || dir.nick === "") return "Not granted yet";
	return dir.nick;
}

export function DirectoryFacts({ dir, rooms }: { dir: DirView; rooms: number }) {
	// The same derivation the rows on this directory read, so a reader comparing
	// the two is comparing two readings of one connection rather than two
	// opinions about it.
	const connection = dirConnection(dir.session, dir.statusText);
	return (
		<dl className="dirfacts">
			<dt>Connection</dt>
			<dd>
				<span className={"dot " + dir.session} aria-hidden="true" />
				{connection.said}
				{
					/* And what it is doing, whenever it is doing something worth
					    saying. A row on this directory carries the phase, because a
					    narrow caption line has room for that beside the name it also
					    has to carry. The sentence is the half that needs a surface of
					    its own, and this is the surface that caption opens.

					    It is said at every phase, because the net layer writes these
					    for a healthy session too, reaching a locator or entering a
					    room, and this card is the one surface that is about this
					    directory rather than about the reader. */
				}
				{connection.why !== "" && <span className="dirfact-why">{connection.why}</span>}
			</dd>
			<dt>Your name</dt>
			<dd>{grantedNameSaid(dir)}</dd>
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
