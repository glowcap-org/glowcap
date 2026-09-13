// What is known about one directory this tab holds, on its own surface.
//
// Every conversation names the directory it is on, and pressing those words
// opens that directory. This card still answers the three questions a locator
// raises and a name cannot, from the directory conversation's title — the same
// pattern a room's title uses. That title's close mark asks to leave, in this
// same card, rather than putting the view away. Settings
// keeps this page's locators and opens that same conversation for the directory
// that served the page.

import { memo, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useShallow } from "zustand/react/shallow";
import type { DirId, DirView } from "../types.ts";
import { useRoomsState } from "../hooks.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { directoryName } from "../text.ts";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { ModalHead } from "../ModalHead.tsx";
import { Confirm } from "../Confirm.tsx";
import { Button } from "../Button.tsx";
import { StandingMenu } from "../Standing.tsx";
import { CopyField } from "../Copy.tsx";
import { Icon } from "../icons.tsx";
import { DirectoryFacts, GrantedNameNote } from "./DirectoryFacts.tsx";
import { Said } from "../Said.tsx";
import { actionRefusal } from "../error_text.ts";
import {
	directoryAnd,
	directoryLeaveAsk,
	directoryLeaveCommit,
	directoryLeaveDoor,
	directoryLeaveKeep,
	directoryLeaveLabel,
	directoryLeaveNameGoesBack,
	directoryLinesCount,
	directoryNothingOpen,
	directoryRetry,
	directoryRetrying,
	directoryRoomsCount,
	directoryThisCloses,
	factCopyLocatorFor,
} from "../../../lib/text/conversation.ts";
import { memberYouAre } from "../../../lib/text/conversation.ts";

/** Stays mounted through the close transition so the card can leave the way
 * it arrived. The open/closed decision still belongs out here: the dialog
 * hook keys on that boolean, not on its own mount. */
export const DirectoryCard = memo(function DirectoryCard(
	{ dir, mark, standing, homeDir, canInteract, askingLeave, onLayer }: {
		dir: DirView | null;
		mark: string | undefined;
		standing: string;
		homeDir: DirId | null;
		canInteract: boolean;
		askingLeave: boolean;
		onLayer: (held: boolean) => void;
	},
) {
	const occupancy = useRoomsState(
		useShallow((state) => {
			if (dir == null) return { rooms: 0, lines: 0 };
			let rooms = 0;
			let lines = 0;
			for (const conv of state.convs.values()) {
				if (conv.dir !== dir.id) continue;
				if (conv.type === "room") rooms++;
				else if (conv.type === "dm") lines++;
			}
			return { rooms, lines };
		}),
	);
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
	// the directory while occupancy has already zeroed rewrites the card as
	// it leaves, so the reverse transition would show facts that were never true.
	const last = useRef<View | null>(
		dir === null ? null : {
			dir,
			rooms: occupancy.rooms,
			lines: occupancy.lines,
			mark,
			standing,
			homeDir,
			canInteract,
		},
	);
	if (dir !== null) {
		last.current = {
			dir,
			rooms: occupancy.rooms,
			lines: occupancy.lines,
			mark,
			standing,
			homeDir,
			canInteract,
		};
	}
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
			askingLeave={askingLeave}
		/>
	);
});

/** What leaving costs, in the things a reader would miss. Counted rather than
 * described, because "your conversations" is exactly the wording that makes
 * somebody press it and then find out what it meant. */
function whatGoes(rooms: number, lines: number): string {
	const said: string[] = [];
	if (rooms > 0) said.push(directoryRoomsCount(rooms));
	if (lines > 0) said.push(directoryLinesCount(lines));
	if (said.length === 0) return directoryNothingOpen;
	return directoryThisCloses(said.join(directoryAnd));
}

function DirectoryDialog(
	{ open, onExited, dir, rooms, lines, mark, standing, homeDir, canInteract, askingLeave }: {
		open: boolean;
		onExited: () => void;
		dir: DirView;
		rooms: number;
		lines: number;
		mark: string | undefined;
		standing: string;
		homeDir: DirId | null;
		canInteract: boolean;
		askingLeave: boolean;
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
	// anyway. The title's mark can open this card already asking; Stay and the
	// card's own Leave control still own the local answer. Closing must not
	// rewrite that answer, or the exit transition would drop the question.
	const [asking, setAsking] = useState(askingLeave);
	const [retrying, setRetrying] = useState(false);
	const [retryWhy, setRetryWhy] = useState("");
	useEffect(() => {
		if (askingLeave) setAsking(true);
		else if (open) setAsking(false);
	}, [askingLeave, open]);
	const name = directoryName(dir.id, homeDir);
	const retry = (): void => {
		if (retrying) return;
		setRetrying(true);
		setRetryWhy("");
		void actionRefusal(() => session.reachDirectory(dir.locator, { kind: "exact", name: dir.requestedNick })).then(
			setRetryWhy,
		)
			.finally(() => setRetrying(false));
	};
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
				<div className="modal-body">
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
							text={dir.locator}
							label={factCopyLocatorFor(name)}
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
							<span>{memberYouAre}</span>
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
									    that makes somebody press it and then find out what it meant.
									    The title's close mark lands on this same question. */
					}
					{canInteract && (asking
						? (
							<Confirm
								id="dircardLeaveSaid"
								label={directoryLeaveLabel(name)}
								say={`${directoryLeaveAsk(name)} ${
									whatGoes(rooms, lines)
								} ${directoryLeaveNameGoesBack}`}
								keep={directoryLeaveKeep}
								commit={directoryLeaveCommit}
								keepId="dircardLeaveStay"
								commitId="dircardLeave"
								onKeep={() => {
									setAsking(false);
									if (askingLeave) browser.aboutDirectory(dir.id);
								}}
								onCommit={() => session.leaveDirectory(dir.id)}
							/>
						)
						: (
							<div className="actions">
								{dir.session === "disconnected" && (
									<Button id="dircardRetry" onClick={retry} disabled={retrying}>
										{retrying ? directoryRetrying : directoryRetry}
									</Button>
								)}
								<Button id="dircardLeaveAsk" variant="quiet" onClick={() => setAsking(true)}>
									{directoryLeaveDoor}
								</Button>
							</div>
						))}
					{retryWhy !== "" && <Said kind="failure">{retryWhy}</Said>}
				</div>
			</div>
		</dialog>
	);
}
