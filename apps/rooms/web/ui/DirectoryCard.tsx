// What is known about one directory this tab holds, on its own surface.
//
// Every row in the rail says which directory it is on, and pressing those words
// is what opens this. It answers the three questions a locator raises and a
// name cannot. Settings
// keeps this page's locators and opens this same card for the directory that
// served the page, so asking about a directory gives one answer wherever it is
// asked.

import { useLayoutEffect, useRef, useState } from "react";
import type { DirId, DirView } from "./types.ts";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import { directoryName } from "./text.ts";
import { useHeldModal, useModalDialog } from "./modal.ts";
import { ModalHead } from "./ModalHead.tsx";
import { Confirm } from "./Confirm.tsx";
import { Button } from "./Button.tsx";
import { StandingMenu } from "./Standing.tsx";
import { CopyField } from "./Copy.tsx";
import { Icon } from "./icons.tsx";
import { DirectoryFacts, GrantedNameNote } from "./DirectoryFacts.tsx";

/** Stays mounted through the close transition so the card can leave the way
 * it arrived. The open/closed decision still belongs out here: the dialog
 * hook keys on that boolean, not on its own mount. */
export function DirectoryCard(
	{ dir, rooms, lines, mark, standing, homeDir, canInteract, onLayer }: {
		dir: DirView | null;
		rooms: number;
		lines: number;
		mark: string | undefined;
		standing: string;
		homeDir: DirId | null;
		canInteract: boolean;
		onLayer: (held: boolean) => void;
	},
) {
	type View = {
		dir: DirView;
		rooms: number;
		lines: number;
		mark: string | undefined;
		standing: string;
		homeDir: DirId | null;
		canInteract: boolean;
	};
	// The whole painted answer shares the card's held lifetime. Retaining only
	// the directory while App has already zeroed its counts rewrites the card as
	// it leaves, so the reverse transition would show facts that were never true.
	const last = useRef<View | null>(
		dir === null ? null : { dir, rooms, lines, mark, standing, homeDir, canInteract },
	);
	if (dir !== null) last.current = { dir, rooms, lines, mark, standing, homeDir, canInteract };
	const shown = last.current;
	const { held, onExited } = useHeldModal(dir !== null);
	useLayoutEffect(() => {
		onLayer(held);
		return () => onLayer(false);
	}, [held, onLayer]);
	if (!held || shown === null) return null;
	return (
		<DirectoryDialog
			open={dir !== null}
			onExited={onExited}
			{...shown}
		/>
	);
}

/** What leaving costs, in the things a reader would miss. Counted rather than
 * described, because "your conversations" is exactly the wording that makes
 * somebody press it and then find out what it meant. */
function whatGoes(rooms: number, lines: number): string {
	const said: string[] = [];
	if (rooms > 0) said.push(rooms === 1 ? "1 room" : rooms + " rooms");
	if (lines > 0) said.push(lines === 1 ? "1 direct conversation" : lines + " direct conversations");
	if (said.length === 0) return "Nothing is open on it.";
	return "This closes " + said.join(" and ") + ".";
}

function DirectoryDialog(
	{ open, onExited, dir, rooms, lines, mark, standing, homeDir, canInteract }: {
		open: boolean;
		onExited: () => void;
		dir: DirView;
		rooms: number;
		lines: number;
		mark: string | undefined;
		standing: string;
		homeDir: DirId | null;
		canInteract: boolean;
	},
) {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const close = useRef<HTMLButtonElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	// The hook owns the whole modal lifecycle — showing, Escape, the backdrop
	// press, and where focus lands — so this component never opens a dialog by
	// hand and never has a second way to close one.
	useModalDialog(dialog, () => browser.aboutDirectory(null), close, open, onExited);
	// Asked before it is done, and asked in this card rather than in one over it:
	// a dialog on top of a dialog is a shape neither the browser nor a screen
	// reader handles well, and the question belongs to the thing being described
	// anyway. Local state, because nothing outside this card is waiting on a
	// question this card has not been answered yet.
	const [asking, setAsking] = useState(false);
	const name = directoryName(dir.id, homeDir);
	return (
		// `modal` is the layer; its ::backdrop uses the same `--cover` paint as
		// the phone's `#cover`. `modal-card` is the panel that rises in it. Naming
		// its own shapes instead got this dialog none of that, and it opened as
		// the browser's own grey box in the middle of the screen.
		<dialog ref={dialog} className="modal" aria-labelledby="dircardTitle">
			{
				/* The card wears the directory's own mark, the same one its rows carry
				    in the rail: this card is what is known about that directory, and
				    arriving here from a coloured line to find nothing coloured makes a
				    reader check they opened the right one. Only when the rail is
				    marking at all, so the card never asserts a distinction nothing
				    else on screen is drawing. */
			}
			<div className="modal-card card-plane dircard" data-dir={mark}>
				<ModalHead
					titleId="dircardTitle"
					title={
						<>
							<span className="dircard-mark" aria-hidden="true">
								<Icon name="directory" size={14} />
							</span>
							{name}
						</>
					}
					closeId="dircardClose"
					closeRef={close}
					onClose={() => browser.aboutDirectory(null)}
				/>

				{
					/* No label over the field: the heading above is the directory's name.
				    What the directory is sits in one well — the locator, its facts,
				    and the granted-name note are all one answer. */
				}
				<div className="group well">
					<CopyField
						id="dircardLocator"
						text={session.dirAddress(dir.id)}
						label={"Copy the locator for " + name}
					/>
					<DirectoryFacts dir={dir} rooms={rooms} />
					<GrantedNameNote />
				</div>
				{
					/* Where the reader stands on this one directory, in a well of its
				    own: it is the card's one thing the reader can change, so it does
				    not sit among the facts. Away is a thing you are on a server in
				    IRC, in every channel on it at once, and this is that answer —
				    one level in from the foot of the rail, which is about the reader
				    everywhere. */
				}
				<div className="group well">
					<div className="dircard-standing">
						<span>Where you are here</span>
						<StandingMenu
							id="dircardStanding"
							own={dir.standing}
							effective={dir.standing ?? standing}
							follows="you"
							about={name}
							up
							onSay={(said) => session.setDirStanding(dir.id, said)}
							disabled={!canInteract}
						/>
					</div>
				</div>

				{
					/* Leaving asks first, in the card, with what goes counted rather
					    than described: "your conversations" is exactly the wording
					    that makes somebody press it and then find out what it meant. */
				}
				{canInteract && (asking
					? (
						<Confirm
							id="dircardLeaveSaid"
							label={"Leave " + name}
							say={
								<>
									Leave {name}? {whatGoes(rooms, lines)}{" "}
									The name it granted you goes back to it, and somebody else may take it.
								</>
							}
							keep="Stay"
							commit="Leave"
							commitId="dircardLeave"
							onKeep={() => setAsking(false)}
							onCommit={() => session.leaveDirectory(dir.id)}
						/>
					)
					: (
						<div className="actions">
							<Button id="dircardLeaveAsk" variant="quiet" onClick={() => setAsking(true)}>
								Leave this directory…
							</Button>
						</div>
					))}
			</div>
		</dialog>
	);
}
