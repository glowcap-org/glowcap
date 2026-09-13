// One Rooms member's own identity on a bridged service, drawn from the
// bridge's declared form.
//
// The bridge says what it needs and Rooms decides what that looks like, so
// nothing here knows any service's fields or states. The form is asked for
// when the surface opens and again when the seat moves, because a form is
// declared for the state its bridge is in now. BridgeFormView owns the
// drawing, the secret custody, and the declared second steps; this owns only
// fetching the declaration and routing a submission to the session.

import { useEffect, useRef, useState } from "react";
import { useRoomsSession } from "../controller/session.ts";
import { Said } from "../Said.tsx";
import { BridgeFormView } from "./BridgeFormView.tsx";
import type { BridgeForm } from "../../../lib/bridge/form.ts";
import type { RoomConv } from "../types.ts";
import { refusalText } from "../../../lib/text/failure.ts";

export function BridgeIdentityForm(
	{ conv, connected, stateKey }: { conv: RoomConv; connected: boolean; stateKey: string },
) {
	const session = useRoomsSession();
	const [loaded, setLoaded] = useState<
		{
			session: typeof session;
			key: string;
			stateKey: string;
			form: BridgeForm | null;
		} | null
	>(null);
	const form = loaded?.session === session && loaded.key === conv.key && loaded.stateKey === stateKey
		? loaded.form
		: null;
	const [fetchWhy, setFetchWhy] = useState("");
	// A superseded promise no longer owns this form: a seat change refetching
	// the declaration must not install a stale one over the newer state.
	const fetchRequest = useRef(0);

	useEffect(() => {
		const own = ++fetchRequest.current;
		void Promise.resolve().then(() => session.bridgeForm(conv.key)).then((declared) => {
			if (fetchRequest.current !== own) return;
			setFetchWhy("");
			setLoaded({ session, key: conv.key, stateKey, form: declared });
		}).catch((error) => {
			if (fetchRequest.current === own) setFetchWhy(refusalText(error));
		});
		return () => {
			fetchRequest.current += 1;
		};
	}, [session, conv.key, stateKey]);

	if (form == null) {
		return fetchWhy === "" ? null : <Said id="convcardBridgeWhy" kind="failure">{fetchWhy}</Said>;
	}
	return (
		<div className="group well" role="group" aria-label={form.title}>
			<p className="group-label">{form.title}</p>
			<p className="hint" id="convcardBridgeState">{form.said}</p>
			<BridgeFormView
				form={form}
				idPrefix="convcardBridge"
				connected={connected}
				standingIssue={fetchWhy !== "" ? fetchWhy : conv.bridgeIssue}
				onAct={(action, answers, secrets) =>
					session.submitBridgeForm(conv.key, form.scope, action, answers, secrets)}
			/>
		</div>
	);
}
