// The card the page opens with, and the one it comes back to when you leave a
// room without entering another.
//
// Joining is an async action, so React owns the pending state: the button reads
// "Joining…" for exactly as long as the join is outstanding, including the part
// where the peer session is still opening. That window used to be its own
// bookkeeping — a staged request, a button label written by hand, and a reset
// called from every path that might end the wait — because there was nothing
// holding "this is in flight" except the label itself.

import { useActionState } from "react";
import { MAX_NICK, MAX_ROOM } from "../../lib/limits.ts";
import { directoryName, tooLong } from "./text.ts";
import { usePeer } from "./peer.ts";
import { Button } from "./Button.tsx";
import type { DirId, DirView } from "./types.ts";

type JoinError = { field: "room" | "nick" | "form"; text: string } | null;

export function JoinCard(
	{ shown, room, locator, nick, dirs, homeDir }: {
		shown: boolean;
		room: string;
		locator: string;
		nick: string;
		/** Every directory this tab already holds, offered under the field so an
		 * address that is already known does not have to be typed or pasted again. */
		dirs: ReadonlyMap<DirId, DirView>;
		homeDir: DirId | null;
	},
) {
	const peer = usePeer();
	const [error, join, joining] = useActionState(async (_was: JoinError, form: FormData): Promise<JoinError> => {
		const room = String(form.get("room") ?? "").trim() || "general";
		const locator = String(form.get("locator") ?? "").trim();
		const nick = String(form.get("nick") ?? "").trim() || "guest";
		if (nick.length > MAX_NICK) return { field: "nick", text: tooLong("name", MAX_NICK) };
		if (room.length > MAX_ROOM) return { field: "room", text: tooLong("room name", MAX_ROOM) };
		const text = await peer.join({ room, locator }, nick);
		return text === "" ? null : { field: "form", text };
	}, null);

	return (
		<div className="join-wrap" id="joinScreen" style={{ display: shown ? "" : "none" }}>
			<form id="joinForm" className="join" action={join}>
				<h2>Join a room</h2>
				<p className="lead">
					No account is required. Name a room in this page's directory, or paste another directory's OCapN
					locator. A room that does not exist yet opens when you enter it. Display names are not verified.
				</p>
				<label htmlFor="locator">
					Directory locator <span className="optional">Optional</span>
				</label>
				<input
					id="locator"
					name="locator"
					type="text"
					inputMode="url"
					placeholder="ocapn://…iroh"
					aria-label="Directory locator"
					value={locator}
					onChange={(e) => peer.setJoinDraft({ draftLocator: e.target.value })}
					autoComplete="off"
					spellCheck={false}
				/>
				{
					/* The addresses already in hand, under the field they fill. A locator
				    is forty characters nobody can retype, and every one of these was
				    typed or pasted once already; the only reason the field is empty on
				    the way back to it is that the field is where a *new* one goes.
				    Leaving it empty means this page's own directory, so that one clears
				    rather than fills. */
				}
				<p className="locator-picks">
					<Button
						variant="link"
						aria-label="Use this directory"
						aria-pressed={locator.trim() === ""}
						onClick={() => peer.setJoinDraft({ draftLocator: "" })}
					>
						this directory
					</Button>
					{[...dirs.values()]
						.filter((dir) => dir.id !== homeDir)
						.map((dir) => (
							<Button
								key={dir.id}
								variant="link"
								title={dir.id}
								aria-label={"Use " + directoryName(dir.id, homeDir)}
								aria-pressed={locator.trim() === dir.id}
								onClick={() => peer.setJoinDraft({ draftLocator: dir.id })}
							>
								{directoryName(dir.id, homeDir)}
							</Button>
						))}
				</p>
				<label htmlFor="room">Room</label>
				<input
					id="room"
					name="room"
					placeholder="general"
					aria-label="Room name"
					aria-describedby={error?.field === "room" ? "joinError" : undefined}
					aria-invalid={error?.field === "room"}
					maxLength={MAX_ROOM}
					value={room}
					onChange={(e) => peer.setJoinDraft({ draftRoom: e.target.value })}
				/>
				<label htmlFor="nick">Display name</label>
				<input
					id="nick"
					name="nick"
					placeholder="your name"
					aria-describedby={error?.field === "nick" ? "joinError" : undefined}
					aria-invalid={error?.field === "nick"}
					maxLength={MAX_NICK}
					value={nick}
					onChange={(e) => peer.setJoinDraft({ draftNick: e.target.value })}
				/>
				<p id="joinError" className="error" role="alert">{error?.text ?? ""}</p>
				<Button type="submit" id="joinBtn" busy={joining}>
					{joining ? "Joining…" : "Join room"}
				</Button>
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
