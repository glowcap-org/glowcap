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
import { usePeer } from "./peer.ts";
import { directoryName } from "./text.ts";
import { useHeldModal, useModalDialog } from "./modal.ts";
import { IconButton } from "./IconButton.tsx";
import { Button } from "./Button.tsx";
import { StandingMenu } from "./Standing.tsx";
import { CopyField } from "./Copy.tsx";
import { Icon } from "./icons.tsx";
import { DirectoryFacts, GrantedNameNote } from "./DirectoryFacts.tsx";

/** Stays mounted through the close transition so the card can leave the way
 * it arrived. The open/closed decision still belongs out here: the dialog
 * hook keys on that boolean, not on its own mount. */
export function DirectoryCard(
	{ dir, rooms, lines, mark, standing, homeDir, onLayer }: {
		dir: DirView | null;
		rooms: number;
		lines: number;
		mark: string | undefined;
		standing: string;
		homeDir: DirId | null;
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
	};
	// The whole painted answer shares the card's held lifetime. Retaining only
	// the directory while App has already zeroed its counts rewrites the card as
	// it leaves, so the reverse transition would show facts that were never true.
	const last = useRef<View | null>(
		dir === null ? null : { dir, rooms, lines, mark, standing, homeDir },
	);
	if (dir !== null) last.current = { dir, rooms, lines, mark, standing, homeDir };
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
	{ open, onExited, dir, rooms, lines, mark, standing, homeDir }: {
		open: boolean;
		onExited: () => void;
		dir: DirView;
		rooms: number;
		lines: number;
		mark: string | undefined;
		standing: string;
		homeDir: DirId | null;
	},
) {
	const peer = usePeer();
	const close = useRef<HTMLButtonElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	// The hook owns the whole modal lifecycle — showing, Escape, the backdrop
	// press, and where focus lands — so this component never opens a dialog by
	// hand and never has a second way to close one.
	useModalDialog(dialog, () => peer.aboutDirectory(null), close, open, onExited);
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
				<div className="settings-head-row">
					<h2 id="dircardTitle">
						<span className="dircard-mark" aria-hidden="true">
							<Icon name="directory" size={14} />
						</span>
						{name}
					</h2>
					<IconButton
						ref={close}
						id="dircardClose"
						icon="close"
						label="Close"
						size="small"
						variant="ghost"
						onClick={() => peer.aboutDirectory(null)}
					/>
				</div>

				{
					/* No label over the field: the heading above is the directory's name.
				    What the directory is sits in one well — the locator, its facts,
				    and the granted-name note are all one answer. */
				}
				<div className="group well">
					<CopyField
						id="dircardLocator"
						text={peer.dirAddress(dir.id)}
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
							onSay={(said) => peer.setDirStanding(dir.id, said)}
						/>
					</div>
				</div>

				{
					/* Stacked as this card's own children, the way Settings stacks its
				    save and its close: the panel is a column with one gap, so a row
				    wrapper here would be a second opinion about how far apart two
				    buttons in a card stand. */
				}
				{asking
					? (
						<>
							<p className="hint" id="dircardLeaveSaid">
								Leave {name}? {whatGoes(rooms, lines)}{" "}
								The name it granted you goes back to it, and somebody else may take it.
							</p>
							<Button
								id="dircardLeave"
								aria-describedby="dircardLeaveSaid"
								onClick={() => peer.leaveDirectory(dir.id)}
							>
								Leave
							</Button>
							<Button variant="quiet" onClick={() => setAsking(false)}>Stay</Button>
						</>
					)
					: (
						<Button id="dircardLeaveAsk" variant="quiet" onClick={() => setAsking(true)}>
							Leave this directory
						</Button>
					)}
			</div>
		</dialog>
	);
}
