// What is known about one directory this tab holds, on its own surface.
//
// A room's row says which directory it is on; this is what that line opens. It
// answers the three questions a locator raises and a name cannot, and it answers
// them with the same block Settings uses, so asking about a directory gives one
// answer wherever it is asked.
//
// Only for a directory that is not the page's own. Settings already describes
// this directory and nothing else, so asking about that one opens Settings
// rather than a second surface repeating it; see `net.aboutDirectory`. That
// split is why this card never has to say *which* directory it is describing in
// the way Settings would have to if it grew the same job.

import { useRef, useState } from "react";
import type { DirView } from "./types.ts";
import { usePeer } from "./peer.ts";
import { directoryName } from "./text.ts";
import { useModalDialog } from "./modal.ts";
import { IconButton } from "./IconButton.tsx";
import { Button } from "./Button.tsx";
import { CopyField } from "./Copy.tsx";
import { Icon } from "./icons.tsx";
import { DirectoryFacts, GrantedNameNote } from "./DirectoryFacts.tsx";

/** Mounted only while a directory is being asked about, so the dialog it holds
 * opens on mount the way every other modal here does. The hook that runs the
 * modal lifecycle keys on nothing but its own mount, which is exactly why the
 * open/closed decision belongs out here rather than inside it. */
export function DirectoryCard(
	{ dir, rooms, lines, marked }: { dir: DirView | null; rooms: number; lines: number; marked: boolean },
) {
	return dir === null ? null : <DirectoryDialog dir={dir} rooms={rooms} lines={lines} marked={marked} />;
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
	{ dir, rooms, lines, marked }: { dir: DirView; rooms: number; lines: number; marked: boolean },
) {
	const peer = usePeer();
	const close = useRef<HTMLButtonElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	// The hook owns the whole modal lifecycle — showing, Escape, the backdrop
	// press, and where focus lands — so this component never opens a dialog by
	// hand and never has a second way to close one.
	useModalDialog(dialog, () => peer.aboutDirectory(null), close);
	// Asked before it is done, and asked in this card rather than in one over it:
	// a dialog on top of a dialog is a shape neither the browser nor a screen
	// reader handles well, and the question belongs to the thing being described
	// anyway. Local state, because nothing outside this card is waiting on a
	// question this card has not been answered yet.
	const [asking, setAsking] = useState(false);
	const name = directoryName(dir.id, null);
	return (
		// The two classes every modal here wears: `modal` is the layer that dims
		// and blurs the page, `modal-card` the panel that rises in it. Naming its
		// own shapes instead got this dialog none of that, and it opened as the
		// browser's own grey box in the middle of the screen.
		<dialog ref={dialog} className="modal" aria-labelledby="dircardTitle">
			{
				/* The card wears the directory's own mark, the same one its rows carry
				    in the rail: this card is what is known about that directory, and
				    arriving here from a coloured line to find nothing coloured makes a
				    reader check they opened the right one. Only when the rail is
				    marking at all, so the card never asserts a distinction nothing
				    else on screen is drawing. */
			}
			<div className="modal-card dircard" data-dir={marked ? dir.slot : undefined}>
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
					/* No label over the field: the heading above is the directory's name,
				    and Settings says the same three things about this page's own
				    directory under the same shape. */
				}
				<div className="group">
					<CopyField id="dircardLocator" text={dir.id} label={"Copy the locator for " + name} />
					<DirectoryFacts dir={dir} rooms={rooms} />
					<GrantedNameNote />
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
