// The glossary, as its own modal rather than a Settings tab.
//
// Settings leaves without an exit while this is up, the same reason
// Operations does: a dialog on a dialog is a shape neither the browser nor a
// screen reader handles well. The title row is the same one Settings uses, so the
// Help control stays on screen and can sit pressed while this layer is the
// one answering.

import { lazy, memo, Suspense, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useHeldModal, useModalDialog } from "./modal.ts";
import { loadKitchen, prefetch } from "./chunks.ts";
import { LoadingSurface } from "./Loading.tsx";
import { SettingsHead } from "./SettingsHead.tsx";
import { Button } from "./Button.tsx";
import { ErrorBoundary } from "./ErrorBoundary.tsx";
import { CopyField } from "./Copy.tsx";

const KitchenSink = lazy(() => loadKitchen().then((m) => ({ default: m.default })));

export const Help = memo(function Help(
	{ open, retain = false, theme, notifyOn, onLayer }: {
		open: boolean;
		retain?: boolean;
		theme: "light" | "dark";
		notifyOn: boolean;
		onLayer: (held: boolean) => void;
	},
) {
	const browser = useRoomsBrowser();
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
	useModalDialog(dialog, () => browser.closeHelp(), close, open, onExited, retain);
	if (!held) return null;

	return (
		<dialog
			ref={dialog}
			className="modal"
			aria-labelledby={titleId}
		>
			<form
				className={sink ? "modal-card card-plane kitchen-card" : "modal-card card-plane"}
				onSubmit={(event) => event.preventDefault()}
			>
				<div className="modal-body">
					<SettingsHead
						titleId={titleId}
						title="Help"
						theme={theme}
						notifyOn={notifyOn}
						helpOpen
						named={open}
						closeId={open ? "helpClose" : undefined}
						closeRef={close}
						onClose={() => browser.closeHelp()}
					/>
					{sink
						? (
							<>
								<div className="actions" data-align="start">
									<Button id="kitchenBack" variant="quiet" onClick={() => setSink(false)}>
										Back to the glossary
									</Button>
								</div>
								<ErrorBoundary part="parts catalog">
									<Suspense fallback={<LoadingSurface what="the parts catalog" layout="catalog" />}>
										<KitchenSink />
									</Suspense>
								</ErrorBoundary>
							</>
						)
						: (
							<>
								<dl className="glossary">
									<div>
										<dt>Directory</dt>
										<dd>
											The object this page starts from. Rooms live on it, and fetching it is how a
											peer arrives.
										</dd>
									</div>
									<div>
										<dt>Locator</dt>
										<dd>
											A peer address: hostname:port for plain TCP, or an ocapn:// URI for other
											transports. A sturdyref adds an object's unguessable name.
										</dd>
									</div>
									<div>
										<dt>Capability</dt>
										<dd>
											A reference whose possession is permission, without a separate account
											check.
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
												onPointerEnter={() => prefetch(loadKitchen)}
												onFocus={() => prefetch(loadKitchen)}
												onClick={() => setSink(true)}
											>
												secret
											</button>, unguessable name a peer will look up for you. Each operations
											capability is published under one when the server starts with one of those
											flags (--diagnostics, --admin-listeners, --operator, or --peering). That is
											what the server prints. A durable room entry link is named by one too.
										</dd>
									</div>
									<div>
										<dt>Sturdyref</dt>
										<dd>
											A locator and swiss number kept for later. Redeeming it asks that peer to
											honor the name. A room entry link is one.
										</dd>
									</div>
								</dl>
							</>
						)}
					<CopyField
						text={document.documentElement.dataset.uiBuild ?? null}
						label="Copy build"
					/>
				</div>
			</form>
		</dialog>
	);
});
