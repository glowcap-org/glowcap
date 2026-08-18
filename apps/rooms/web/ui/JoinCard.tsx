// The card the page opens with, and the one it comes back to when you leave a
// room without entering another.
//
// Joining is an async action, so React owns the pending state: the button reads
// "Joining…" for exactly as long as the join is outstanding, including the part
// where the peer session is still opening. That window used to be its own
// bookkeeping — a staged request, a button label written by hand, and a reset
// called from every path that might end the wait — because there was nothing
// holding "this is in flight" except the label itself.

import { useActionState, useRef } from "react";
import { MAX_NICK, MAX_ROOM } from "../../lib/limits.ts";
import { directoryName, tooLong } from "./text.ts";
import { identifierField } from "./field.ts";
import { usePeer } from "./peer.ts";
import { Avatar } from "./Avatar.tsx";
import { Button } from "./Button.tsx";
import { Icon } from "./icons.tsx";
import {
	JOIN_DEFAULT_NICK,
	JOIN_DEFAULT_ROOM,
	type JoinAnswers,
	joinLead,
	joinLocatorPlaceholder,
	thisDirectoryLocator,
} from "./joining.ts";
import { JoinField, JoinPrefix } from "./JoinField.tsx";
import { MenuList, MenuRow, useMenu } from "./Menu.tsx";
import { Said } from "./Said.tsx";
import { type DirId, dirMark, type DirView } from "./types.ts";
import { WorkingAction } from "./WorkingAction.tsx";

type JoinError = { field: "room" | "nick" | "form"; text: string } | null;

export function JoinCard(
	{ shown, answers, dirs, homeDir }: {
		shown: boolean;
		/** Every field, with the evidence behind it. Resolved from the act that
		 * put this card up rather than held as state, so the same card is a gate
		 * on a link and a blank form from the rail without either one having to
		 * clear up after the other. The lock rides along for the same reason the
		 * others do: the rail's room panel names this room too, and its lock has
		 * to be this lock. */
		answers: JoinAnswers;
		/** Every directory this tab already holds. Offered from the locator field's
		 * own mark, so an address that is already known does not have to be typed
		 * or pasted again. */
		dirs: ReadonlyMap<DirId, DirView>;
		homeDir: DirId | null;
	},
) {
	const peer = usePeer();
	const room = answers.room.value;
	const locator = answers.locator.value;
	const nick = answers.nick.value;
	const secret = answers.secret.value;
	const halt = useRef<AbortController | null>(null);
	const [error, join, joining] = useActionState(async (_was: JoinError, form: FormData): Promise<JoinError> => {
		halt.current?.abort();
		const run = new AbortController();
		halt.current = run;
		const room = String(form.get("room") ?? "").trim() || JOIN_DEFAULT_ROOM;
		// Empty, the bare home authority, and home's hinted route are one
		// destination: this page's own directory, reached over the session
		// already open rather than by a fresh dial.
		const typed = thisDirectoryLocator(String(form.get("locator") ?? ""), homeDir);
		const locator = typed !== "" && homeDir !== null && peer.directoryId(typed.trim()) === homeDir ? "" : typed;
		const nick = String(form.get("nick") ?? "").trim() || JOIN_DEFAULT_NICK;
		if (nick.length > MAX_NICK) return { field: "nick", text: tooLong("name", MAX_NICK) };
		if (room.length > MAX_ROOM) return { field: "room", text: tooLong("room name", MAX_ROOM) };
		try {
			const text = await peer.join({ room, locator, hidden: secret }, nick, run.signal);
			if (run.signal.aborted) return null;
			if (text !== "") return { field: "form", text };
			// The lock is an intention about the room just made, and it is now
			// spent: left pressed, the next name typed here would mint a private
			// room nobody asked for.
			if (secret) peer.editJoin({ secret: false });
			return null;
		} finally {
			if (halt.current === run) halt.current = null;
		}
	}, null);
	const aimed = destination(locator, peer.directoryId(locator.trim()), dirs, homeDir);
	const who = nick.trim() || JOIN_DEFAULT_NICK;

	return (
		<div className="join-wrap" id="joinScreen" hidden={!shown}>
			<form id="joinForm" className="join" data-dir={aimed.mark} action={join}>
				<h2>Join a room</h2>
				<p className="lead">{joinLead(answers, aimed.name)}</p>
				<div className="join-fields" inert={joining || undefined}>
					<label htmlFor="locator">
						Directory locator <span className="optional">Optional</span>
					</label>
					<JoinLocator
						locator={locator}
						dirs={dirs}
						homeDir={homeDir}
						onPick={(next) => peer.editJoin({ locator: next })}
						onType={(next) => peer.editJoin({ locator: next })}
					/>
					<label htmlFor="room">{secret ? "Private room" : "Room"}</label>
					<JoinField invalid={error?.field === "room"}>
						<JoinPrefix
							id="joinPrivate"
							label={secret
								? "Making a private room: only people you hand it to can reach it"
								: "Make this room private, so only people you hand it to can reach it"}
							aria-pressed={secret}
							onMouseDown={(event) => event.preventDefault()}
							onClick={() => peer.editJoin({ secret: !secret })}
						>
							{secret
								? <Icon name="lock" size={18} />
								: <span className="join-hash" aria-hidden="true">#</span>}
						</JoinPrefix>
						<input
							id="room"
							name="room"
							placeholder={JOIN_DEFAULT_ROOM}
							enterKeyHint="next"
							aria-describedby={error?.field === "room" ? "joinError" : undefined}
							aria-invalid={error?.field === "room"}
							maxLength={MAX_ROOM}
							value={room}
							onChange={(e) => peer.editJoin({ room: e.target.value })}
							{...identifierField}
						/>
					</JoinField>
					<label htmlFor="nick">Display name</label>
					<JoinField invalid={error?.field === "nick"}>
						<JoinPrefix label="A picture of you. Choosing one is not offered yet.">
							<Avatar name={who} />
						</JoinPrefix>
						<input
							id="nick"
							name="nick"
							placeholder={JOIN_DEFAULT_NICK}
							enterKeyHint="go"
							{...identifierField}
							autoComplete="nickname"
							aria-describedby={error?.field === "nick" ? "joinError" : undefined}
							aria-invalid={error?.field === "nick"}
							maxLength={MAX_NICK}
							value={nick}
							onChange={(e) => peer.editJoin({ nick: e.target.value })}
						/>
					</JoinField>
				</div>
				<Said id="joinError" kind="failure">{error?.text ?? ""}</Said>
				<WorkingAction
					type="submit"
					id="joinBtn"
					busy={joining}
					stopId="joinStop"
					stopLabel="Stop joining"
					onStop={() => halt.current?.abort()}
				>
					{joining ? "Joining…" : "Join room"}
				</WorkingAction>
				<Button
					id="browseRoomsBtn"
					variant="quiet"
					onClick={() => peer.showRail(true)}
				>
					Browse live rooms
				</Button>
			</form>
		</div>
	);
}

/** Where this card is aimed, as both the mark it wears and the words it uses.
 *
 * One classification rather than two, because the stripe and the opening line
 * are answering the same question and would drift apart asking it separately.
 * The field is empty or names this page's directory, it names another this tab
 * holds, or it names something else; the answer is by identity — `typedAs` is
 * what the text resolves to — so a hinted route and a bare authority are one
 * destination. The card's top stripe stays accent into teal for home, matching
 * Settings, and swaps only the teal stop for a foreign directory's mark. */
function destination(
	locator: string,
	typedAs: DirId | null,
	dirs: ReadonlyMap<DirId, DirView>,
	homeDir: DirId | null,
): { mark: "home" | string | undefined; name: string } {
	const typed = thisDirectoryLocator(locator, homeDir);
	if (typed === "" || (homeDir != null && typedAs === homeDir)) {
		return {
			mark: homeDir != null ? dirMark(homeDir, homeDir, undefined) : undefined,
			name: "this page's directory",
		};
	}
	const held = typedAs != null ? dirs.get(typedAs) : undefined;
	if (held != null) return { mark: dirMark(held.id, homeDir, held.slot), name: directoryName(held.id, homeDir) };
	// Not a directory this tab holds. It may still be a perfectly good address,
	// so it is named the way any directory is named rather than read back as
	// the forty characters somebody pasted.
	return { mark: undefined, name: typedAs != null ? directoryName(typedAs, homeDir) : "that directory" };
}

function JoinLocator(
	{ locator, dirs, homeDir, onPick, onType }: {
		locator: string;
		dirs: ReadonlyMap<DirId, DirView>;
		homeDir: DirId | null;
		onPick: (locator: string) => void;
		onType: (locator: string) => void;
	},
) {
	const peer = usePeer();
	const { open, setOpen, holder, trigger } = useMenu();
	const others = [...dirs.values()].filter((dir) => dir.id !== homeDir);
	const typedAs = peer.directoryId(locator.trim());
	const here = thisDirectoryLocator(locator, homeDir) === "" || (homeDir != null && typedAs === homeDir);
	return (
		<div className="join-field-wrap" ref={holder}>
			<JoinField>
				<JoinPrefix
					id="joinLocator"
					ref={trigger}
					className="join-prefix-dir"
					label={open ? "Hide held directories" : "Choose a held directory"}
					aria-haspopup="menu"
					aria-expanded={open}
					onClick={() => setOpen((was) => !was)}
				>
					<Icon name="directory" size={18} />
				</JoinPrefix>
				<input
					id="locator"
					name="locator"
					type="text"
					inputMode="url"
					enterKeyHint="next"
					placeholder={joinLocatorPlaceholder(homeDir == null ? null : peer.dirAddress(homeDir))}
					value={locator}
					onChange={(e) => onType(e.target.value)}
					{...identifierField}
				/>
			</JoinField>
			{
				/* The addresses already in hand, from the mark that stands for this
				    field. A locator is forty characters nobody can retype, and every one
				    of these was typed or pasted once already; the only reason the field
				    is empty on the way back to it is that the field is where a *new* one
				    goes. Leaving it empty means this page's own directory, so that one
				    clears rather than fills. */
			}
			{open && (
				<MenuList className="locator-picks">
					<MenuRow
						className="line-menu-row"
						first
						marked={here}
						onPick={() => {
							setOpen(false);
							onPick("");
						}}
					>
						this directory
					</MenuRow>
					{others.map((dir) => (
						// A pick fills the field with the full hinted route, the same
						// address every share surface hands out, because the field's
						// value is what a submit dials and the hints are part of what
						// makes it dialable. Matching is by identity, so the row stays
						// marked whether the field holds the route or the bare
						// authority.
						<MenuRow
							key={dir.id}
							className="line-menu-row"
							marked={typedAs === dir.id}
							onPick={() => {
								setOpen(false);
								onPick(peer.dirAddress(dir.id));
							}}
						>
							{directoryName(dir.id, homeDir)}
						</MenuRow>
					))}
				</MenuList>
			)}
		</div>
	);
}
