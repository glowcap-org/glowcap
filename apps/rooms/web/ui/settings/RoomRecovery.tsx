// Explicit re-entry after one room's authority or reachability ended.

import { useState } from "react";
import { Button } from "../Button.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { locatorRefusal } from "../error_text.ts";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import type { RoomConv } from "../types.ts";
import { useChangeGroup, useCommitSettling } from "../commitment.tsx";
import { Said } from "../Said.tsx";

export function RoomRecovery({ conv, blocked }: { conv: RoomConv; blocked: boolean }) {
	const session = useRoomsSession();
	const [link, setLink] = useState("");
	const [recovering, setRecovering] = useState(false);
	const [said, setSaid] = useState("");
	const commit = useCommitSettling();
	const pending = recovering || conv.reconnect === "requested";
	useChangeGroup(`room-recovery:${conv.key}`, {
		dirty: link !== "",
		discard: () => {
			if (recovering) throw new Error("Wait for the room recovery to finish.");
			setLink("");
			setSaid("");
		},
		settling: commit.current,
	});
	const recover = () => {
		if (pending) return;
		commit.begin();
		setRecovering(true);
		setSaid("");
		void session.recoverRoom(conv.key, conv.held ? link : undefined).then((refused) => {
			setSaid(locatorRefusal(refused, "current room entry link"));
			if (refused === "") setLink("");
		}).finally(() => {
			setRecovering(false);
			commit.finish();
		});
	};
	return (
		<>
			<h3 className="well-title overline" id="convcardRecoveryTitle">Restore room access</h3>
			<div className="group well" role="group" aria-labelledby="convcardRecoveryTitle">
				<p className="hint">
					{conv.held
						? conv.link == null
							? "This private room needs a current link. Its label alone cannot find it."
							: "Retry the saved private-room entry link, or replace it with a current link."
						: conv.reconnect != null
						? "The saved link was revoked. Rejoining by name is an explicit choice and may reach a newer room using the same name."
						: "Retry joining this public room by name."}
				</p>
				{conv.held && (
					<Field id="convcardRecoveryLink" label="Current room entry link" said={said}>
						{(wiring) => (
							<input
								id={wiring.id}
								className="field"
								value={link}
								onChange={(event) => {
									setLink(event.currentTarget.value);
									setSaid("");
								}}
								{...identifierField}
								placeholder="ocapn://…/s/…"
								aria-describedby={wiring.describedBy}
								aria-invalid={wiring.invalid}
								disabled={blocked || pending}
							/>
						)}
					</Field>
				)}
				<div className="actions">
					<Button
						id="convcardRecoverRoom"
						busy={pending}
						disabled={blocked || pending || (conv.held && conv.link == null && link.trim() === "")}
						onClick={recover}
					>
						{pending
							? "Restoring room…"
							: conv.held
							? link.trim() === "" && conv.link != null ? "Retry saved link" : "Use current link"
							: "Rejoin by name"}
					</Button>
				</div>
				{!conv.held && said !== "" && <Said kind="failure">{said}</Said>}
			</div>
		</>
	);
}
