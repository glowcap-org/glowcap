// The glossary, as its own modal rather than a Settings tab.
//
// Settings leaves without an exit while this is up, the same reason
// Operations does: a dialog on a dialog is a shape neither the browser nor a
// screen reader handles well. The title row is the same one Settings uses, so the
// Help control stays on screen and can sit pressed while this layer is the
// one answering.
//
// The word "secret" in the glossary is the door to the parts catalog: Help is
// already the window that names what this page is made of, and the catalog is
// the same idea aimed at the controls rather than the words. Only the cursor
// gives the door away — a development surface earns an easter egg's
// affordance. A long refusal in that catalog opens its own card the way this
// dialog sits over Settings: Help leaves without an exit, and closing the
// card puts the catalog back.

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { usePeer } from "./peer.ts";
import { useHeldModal, useModalDialog } from "./modal.ts";
import { SettingsHead } from "./SettingsHead.tsx";
import { KitchenSink } from "./KitchenSink.tsx";
import { Button } from "./Button.tsx";

export function Help(
	{ open, retain = false, theme, notifyOn, onLayer }: {
		open: boolean;
		retain?: boolean;
		theme: "light" | "dark";
		notifyOn: boolean;
		onLayer: (held: boolean) => void;
	},
) {
	const peer = usePeer();
	const titleId = "helpTitle";
	const close = useRef<HTMLButtonElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	const { held, onExited } = useHeldModal(open, retain);
	const [sink, setSink] = useState(false);
	useEffect(() => {
		if (!open && !retain) setSink(false);
	}, [open, retain]);
	useLayoutEffect(() => {
		onLayer(held);
		return () => onLayer(false);
	}, [held, onLayer]);
	useModalDialog(dialog, () => peer.closeHelp(), close, open, onExited, retain);
	if (!held) return null;

	return (
		<dialog
			ref={dialog}
			className="modal"
			aria-labelledby={titleId}
		>
			<form
				className={sink ? "modal-card card-plane kitchen-card" : "modal-card"}
				onSubmit={(event) => event.preventDefault()}
			>
				<SettingsHead
					titleId={titleId}
					title="Help"
					theme={theme}
					notifyOn={notifyOn}
					helpOpen
					named={open}
					closeId={open ? "helpClose" : undefined}
					closeRef={close}
					onClose={() => peer.closeHelp()}
				/>
				{sink
					? (
						<>
							<Button id="kitchenBack" variant="quiet" onClick={() => setSink(false)}>
								Back to the glossary
							</Button>
							<KitchenSink />
						</>
					)
					: (
						<>
							<p className="lead">
								Words this window uses, in the sense it uses them.
							</p>
							<dl className="glossary">
								<div>
									<dt>Directory</dt>
									<dd>
										The starting object this page talks to. Rooms live on it. Fetching{" "}
										<code>directory</code> is how a peer arrives.
									</dd>
								</div>
								<div>
									<dt>Locator</dt>
									<dd>
										An <code>ocapn://</code> address of a peer, and sometimes of one object on it.
									</dd>
								</div>
								<div>
									<dt>Capability</dt>
									<dd>
										A reference you hold. Holding it is the permission to use it; there is no
										separate account check.
									</dd>
								</div>
								<div>
									<dt>Swiss number</dt>
									<dd>
										A{" "}
										<button
											id="glossarySecret"
											type="button"
											className="secret-door"
											onClick={() => setSink(true)}
										>
											secret
										</button>, unguessable name a peer will look up for you. Each operations
										capability is published under one when the app is started with its flag —{" "}
										<code>--diagnostics</code>, <code>--admin-listeners</code>, or{" "}
										<code>--peering</code>{" "}
										— and that is what the server prints. A durable room link is named by one too.
									</dd>
								</div>
								<div>
									<dt>Sturdyref</dt>
									<dd>
										Durable data: a locator plus a swiss number. Redeeming it asks that peer to
										honor the name. A room link is a sturdyref.
									</dd>
								</div>
							</dl>
						</>
					)}
			</form>
		</dialog>
	);
}
