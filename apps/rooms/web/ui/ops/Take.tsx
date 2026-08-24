// The modal that takes one operations capability.
//
// Flipping a toggle on in Settings → Capabilities opens this form: paste the
// swiss number the server printed, fetch the capability on the live directory
// session. The toggle lands on only when the take succeeds — cancel or a
// refused take leaves nothing held. Settings leaves without an exit while
// this is up, because a dialog on a dialog is a shape neither the browser nor
// a screen reader handles well.

import { useLayoutEffect, useRef, useState } from "react";
import { usePeer } from "../peer.ts";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { identifierField } from "../field.ts";
import { Button } from "../Button.tsx";
import { Checkbox } from "../Checkbox.tsx";
import { IconButton } from "../IconButton.tsx";
import { Said } from "../Said.tsx";
import type { OpsCap } from "../types.ts";
import { OPS_CATALOG } from "./catalog.ts";

export function OpsTakeModal(
	{ cap, onLayer }: {
		/** Which capability is being asked for, or null while none is. */
		cap: OpsCap | null;
		onLayer: (held: boolean) => void;
	},
) {
	const peer = usePeer();
	const open = cap !== null;
	const titleId = "opsTakeTitle";
	const field = useRef<HTMLInputElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	// The cap the modal is showing: kept through the close transition, when
	// `cap` has already gone back to null but the form is still on screen.
	const [showing, setShowing] = useState<OpsCap>(cap ?? "listeners");
	const [pasted, setPasted] = useState("");
	const [remember, setRemember] = useState(false);
	const [taking, setTaking] = useState(false);
	const [why, setWhy] = useState<string | null>(null);
	const { held, onExited } = useHeldModal(open);
	useLayoutEffect(() => {
		onLayer(held);
		return () => onLayer(false);
	}, [held, onLayer]);
	useLayoutEffect(() => {
		if (cap !== null) {
			setShowing(cap);
			setPasted("");
			setRemember(false);
			setWhy(null);
		}
	}, [cap]);
	useModalDialog(dialog, () => peer.closeOpsTake(), field, open, onExited);
	if (!held) return null;

	const ask = OPS_CATALOG[showing];
	const take = () => {
		setWhy(null);
		setTaking(true);
		void peer.takeOpsCap(showing, pasted, remember).then((refused) => {
			setTaking(false);
			if (refused !== "") {
				setWhy(refused);
				return;
			}
			peer.closeOpsTake();
		});
	};

	return (
		<dialog
			ref={dialog}
			className="modal"
			aria-labelledby={titleId}
		>
			<form
				className="modal-card card-plane"
				onSubmit={(event) => {
					event.preventDefault();
					take();
				}}
			>
				<div className="settings-head-row">
					<h2 id={titleId}>{ask.label}</h2>
					<IconButton
						id={open ? "opsTakeClose" : undefined}
						icon="close"
						label="Close"
						title="Close"
						size="small"
						variant="ghost"
						onClick={() => peer.closeOpsTake()}
					/>
				</div>
				<p className="lead">
					If started with <code>{ask.flag}</code>, the server prints a swiss number. {ask.how} {ask.lead}
				</p>
				<div className="group well">
					<p className="group-label" id="opsTakeCapLabel">Swiss number</p>
					<input
						ref={field}
						id="opsTakeCap"
						className="field"
						name="capability"
						type="text"
						enterKeyHint="go"
						value={pasted}
						onChange={(event) => setPasted(event.target.value)}
						{...identifierField}
						placeholder="paste the swiss number"
						aria-labelledby="opsTakeCapLabel"
						aria-describedby={why !== null ? "opsTakeWhy" : undefined}
						aria-invalid={why !== null}
					/>
					{why !== null ? <Said id="opsTakeWhy" kind="failure">{why}</Said> : null}
					<label className="check-row">
						<Checkbox
							id="opsTakeRemember"
							checked={remember}
							onChange={(event) => setRemember(event.target.checked)}
						/>
						<span>Remember on this device</span>
					</label>
					<p className="hint">
						A remembered swiss number sits readably in this browser profile, and the number is the whole
						capability: whoever reads it can use it, here or anywhere.
					</p>
				</div>
				<Button type="submit" busy={taking}>Take capability</Button>
			</form>
		</dialog>
	);
}
