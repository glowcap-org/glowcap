// Reconnection is an explicit gesture for one exact directory registration.
// It never resubmits an uncertain message or treats a reused name as identity.
import { useRef, useState } from "react";
import type { DmConv } from "../types.ts";
import { useRoomsState, useSessionPermission } from "../hooks.ts";
import { useRoomsSession } from "../controller/session.ts";
import { actionRefusal } from "../error_text.ts";
import { Button } from "../Button.tsx";
import { Said } from "../Said.tsx";
import { directPeerUnavailable, directReconnect, directReconnecting } from "../../../lib/text/conversation.ts";

export function DirectReconnect({ conv }: { conv: DmConv }) {
	const session = useRoomsSession();
	const permitted = useSessionPermission("interactWorkspace");
	const peer = useRoomsState((state) => state.dirs.get(conv.dir)?.dmablePeers.get(conv.id.toLowerCase()));
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const running = useRef(false);
	const available = conv.peerRegistrationId !== "" && peer?.registrationId === conv.peerRegistrationId;
	const reconnect = () => {
		if (running.current) return;
		running.current = true;
		setBusy(true);
		setWhy("");
		void actionRefusal(() => session.recoverDm(conv.key)).then(setWhy).finally(() => {
			running.current = false;
			setBusy(false);
		});
	};
	return (
		<div className="actions">
			{available && permitted
				? (
					<Button id="dmReconnect" type="button" busy={busy} disabled={busy} onClick={reconnect}>
						{busy ? directReconnecting : directReconnect}
					</Button>
				)
				: !available && <p>{directPeerUnavailable}</p>}
			{why !== "" && <Said kind="failure">{why}</Said>}
		</div>
	);
}
