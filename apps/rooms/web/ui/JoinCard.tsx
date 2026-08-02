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
import { tooLong } from "./text.ts";
import { usePeer } from "./peer.ts";

export function JoinCard(
	{ shown, room, nick }: { shown: boolean; room: string; nick: string },
) {
	const peer = usePeer();
	const [error, join, joining] = useActionState(async (_was: string, form: FormData) => {
		const room = String(form.get("room") ?? "").trim() || "general";
		const nick = String(form.get("nick") ?? "").trim() || "guest";
		if (nick.length > MAX_NICK) return tooLong("name", MAX_NICK);
		if (room.length > MAX_ROOM) return tooLong("room name", MAX_ROOM);
		return await peer.join(room, nick);
	}, "");

	return (
		<div className="join-wrap" id="joinScreen" style={{ display: shown ? "" : "none" }}>
			<form id="joinForm" className="join" action={join}>
				<h2>Join a room</h2>
				<p className="lead">
					Pick a room and a name — capability-secure chat, no account. Entering a room
					that does not exist yet opens it.
				</p>
				<label htmlFor="room">Room</label>
				<input
					id="room"
					name="room"
					placeholder="general"
					aria-label="Room name"
					maxLength={32}
					value={room}
					onChange={(e) => peer.setJoinDraft({ draftRoom: e.target.value })}
				/>
				<label htmlFor="nick">Display name</label>
				<input
					id="nick"
					name="nick"
					placeholder="your name"
					aria-describedby="nickError"
					aria-invalid={error !== ""}
					maxLength={32}
					value={nick}
					onChange={(e) => peer.setJoinDraft({ draftNick: e.target.value })}
				/>
				<p id="nickError" className="error" role="alert">{error}</p>
				<button type="submit" id="joinBtn" disabled={joining}>
					{joining ? "Joining…" : "Join room"}
				</button>
				<button
					type="button"
					id="browseRoomsBtn"
					className="ghost-link"
					onClick={() => peer.showRail(true)}
				>
					Browse live rooms
				</button>
			</form>
		</div>
	);
}
