// Explicit re-entry after one room's authority or reachability ended.

import { useState } from "react";
import {
	recoveryLinkLabel,
	recoveryLinkRevoked,
	recoveryPrivateNeedsLink,
	recoveryPrivateRetry,
	recoveryPublicRetry,
	recoveryWait,
} from "../../../lib/text/settings.ts";
import {
	recoveryRejoinByName,
	recoveryRestoring,
	recoveryRetrySaved,
	recoveryUseCurrent,
	roomRecoveryTitle,
} from "../../../lib/text/settings.ts";
import { Button } from "../Button.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { actionRefusal, locatorRefusal } from "../error_text.ts";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import type { RoomConv } from "../types.ts";
import { useChangeGroup, useCommitSettling } from "../commitment.tsx";
import { Said } from "../Said.tsx";
import { sturdyrefPlaceholder } from "../../../lib/text/controls.ts";

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
			if (recovering) throw new Error(recoveryWait);
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
		void actionRefusal(() => session.recoverRoom(conv.key, conv.held ? link : undefined)).then((refused) => {
			setSaid(locatorRefusal(refused, "current room entry link"));
			if (refused === "") setLink("");
		}).finally(() => {
			setRecovering(false);
			commit.finish();
		});
	};
	return (
		<>
			<h3 className="well-title overline" id="convcardRecoveryTitle">{roomRecoveryTitle}</h3>
			<div className="group well" role="group" aria-labelledby="convcardRecoveryTitle">
				<p className="hint">
					{conv.held
						? conv.linkToken == null ? recoveryPrivateNeedsLink : recoveryPrivateRetry
						: conv.reconnect != null
						? recoveryLinkRevoked
						: recoveryPublicRetry}
				</p>
				{conv.held && (
					<Field id="convcardRecoveryLink" label={recoveryLinkLabel} said={said}>
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
								placeholder={sturdyrefPlaceholder}
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
						disabled={blocked || pending || (conv.held && conv.linkToken == null && link.trim() === "")}
						onClick={recover}
					>
						{pending
							? recoveryRestoring
							: conv.held
							? link.trim() === "" && conv.linkToken != null ? recoveryRetrySaved : recoveryUseCurrent
							: recoveryRejoinByName}
					</Button>
				</div>
				{!conv.held && said !== "" && <Said kind="failure">{said}</Said>}
			</div>
		</>
	);
}
