// Help, as its own modal rather than a Settings tab: three tabs of its own,
// what Rooms is, how to write a message, and the protocol names for what the
// reader has been using.
//
// Settings leaves without an exit while this is up, the same reason
// Operations does: a dialog on a dialog is a shape neither the browser nor a
// screen reader handles well. The title row is the same one Settings uses, so the
// Help control stays on screen and can sit pressed while this layer is the
// one answering.

import { Fragment, lazy, memo, Suspense, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { loadKitchen, prefetch } from "../chunks.ts";
import { LoadingSurface } from "../Loading.tsx";
import { SettingsHead } from "../settings/SettingsHead.tsx";
import { Button } from "../Button.tsx";
import { ErrorBoundary } from "../ErrorBoundary.tsx";
import { CopyField } from "../Copy.tsx";
import { type TabFace, Tabs } from "../Tabs.tsx";
import type { HelpTab } from "../store/core.ts";
import {
	helpAbout,
	helpAboutCredit,
	helpAboutLead,
	helpCapability,
	helpCapabilitySaid,
	helpCopyBuild,
	helpDirectory,
	helpDirectorySaid,
	helpGlossaryLead,
	helpKitchenBack,
	helpLocator,
	helpLocatorSaid,
	helpPartsCatalog,
	helpSturdyref,
	helpSturdyrefSaid,
	helpSwiss,
	helpSwissAfter,
	helpSwissBefore,
	helpSwissSecret,
	helpTabAbout,
	helpTabGlossary,
	helpTabWriting,
	helpTitle,
	type LinkedText,
} from "../../../lib/text/mod.ts";
import {
	writingExamples,
	writingLead,
	writingMore,
	writingSeeColumn,
	writingShortcuts,
	writingShortcutsTitle,
	writingTypeColumn,
} from "../../../lib/text/writing.ts";
import { RichText } from "./RichText.tsx";
import { keyLabel } from "../composer/keys.ts";
import { useRoomsState } from "../hooks.ts";

const KitchenSink = lazy(() => loadKitchen().then((m) => ({ default: m.default })));

/** A catalog sentence with links in it. Every link leaves the page, so each
 * opens beside it rather than over the room. */
function Linked({ parts }: { parts: LinkedText }) {
	return parts.map((part, at) =>
		typeof part === "string"
			? <Fragment key={at}>{part}</Fragment>
			: <a key={at} href={part.href} target="_blank" rel="noreferrer">{part.text}</a>
	);
}

const tabs: readonly TabFace<HelpTab>[] = [
	{ id: "about", domId: "helpAboutTab", label: helpTabAbout, panelId: "helpAboutPanel" },
	{ id: "writing", domId: "helpWritingTab", label: helpTabWriting, panelId: "helpWritingPanel" },
	{ id: "glossary", domId: "helpGlossaryTab", label: helpTabGlossary, panelId: "helpGlossaryPanel" },
];

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
	// The store is the one authority on the tab, so a control that opens Help
	// on one and the tab bar itself cannot disagree.
	const pane = useRoomsState((state) => state.helpTab);
	if (!held) return null;

	return (
		<dialog
			ref={dialog}
			className="modal"
			aria-labelledby={titleId}
		>
			<form
				className={sink ? "modal-card card-plane kitchen-card" : "modal-card card-plane help-card"}
				onSubmit={(event) => event.preventDefault()}
			>
				<div className="modal-body">
					<SettingsHead
						titleId={titleId}
						title={helpTitle}
						theme={theme}
						notifyOn={notifyOn}
						helpOpen
						named={open}
						closeId={open ? "helpClose" : undefined}
						closeRef={close}
						onClose={() => browser.closeHelp()}
					>
						{!sink && (
							<Tabs
								id="helpTabs"
								tabs={tabs}
								selected={pane}
								labelledBy={titleId}
								onSelect={(next) => browser.setHelpTab(next)}
							/>
						)}
					</SettingsHead>
					{sink
						? (
							<>
								<div className="actions" data-align="start">
									<Button id="kitchenBack" variant="quiet" onClick={() => setSink(false)}>
										{helpKitchenBack}
									</Button>
								</div>
								<ErrorBoundary part={helpPartsCatalog}>
									<Suspense fallback={<LoadingSurface what={helpPartsCatalog} layout="catalog" />}>
										<KitchenSink />
									</Suspense>
								</ErrorBoundary>
							</>
						)
						: pane === "about"
						? (
							<div
								id="helpAboutPanel"
								className="help-panel"
								role="tabpanel"
								aria-labelledby="helpAboutTab"
							>
								<p className="help-lead">
									<Linked parts={helpAboutLead} />
								</p>
								<dl className="glossary">
									{helpAbout.map((fact) => (
										<div key={fact.title}>
											<dt>{fact.title}</dt>
											<dd>{fact.said}</dd>
										</div>
									))}
								</dl>
								<p className="hint">
									<Linked parts={helpAboutCredit} />
								</p>
							</div>
						)
						: pane === "writing"
						? (
							<div
								id="helpWritingPanel"
								className="help-panel"
								role="tabpanel"
								aria-labelledby="helpWritingTab"
							>
								<p className="hint">
									<Linked parts={writingLead} />
								</p>
								{
									/* A table read across one row: the source on the left, and on
								    the right what the parser a message goes through makes of it,
								    drawn as a message. The help shows the grammar rather than
								    describing it, so it cannot drift from what a message actually
								    becomes. Each example is its own row group under its name. */
								}
								<table className="help-writing">
									<thead>
										<tr>
											<th scope="col">{writingTypeColumn}</th>
											<th scope="col">{writingSeeColumn}</th>
										</tr>
									</thead>
									{writingExamples.map((example) => (
										<tbody key={example.what}>
											<tr>
												<th scope="rowgroup" colSpan={2}>{example.what}</th>
											</tr>
											<tr>
												<td className="help-source">
													<pre><code>{example.source}</code></pre>
												</td>
												<td className="bubble help-example">
													<RichText text={example.source} nick="" />
												</td>
											</tr>
										</tbody>
									))}
								</table>
								<p className="hint">
									<Linked parts={writingMore} />
								</p>
								<h4 className="help-keys-title">{writingShortcutsTitle}</h4>
								<ul className="help-keys">
									{writingShortcuts.map((shortcut) => (
										<li key={shortcut.what}>
											<span>
												{shortcut.keys.map((key, at) => (
													<Fragment key={key}>
														{at > 0 && " "}
														<kbd>{keyLabel(key)}</kbd>
													</Fragment>
												))}
											</span>
											<span>{shortcut.what}</span>
										</li>
									))}
								</ul>
							</div>
						)
						: (
							<div
								id="helpGlossaryPanel"
								className="help-panel"
								role="tabpanel"
								aria-labelledby="helpGlossaryTab"
							>
								<p className="hint">{helpGlossaryLead}</p>
								<dl className="glossary">
									<div>
										<dt>{helpDirectory}</dt>
										<dd>{helpDirectorySaid}</dd>
									</div>
									<div>
										<dt>{helpLocator}</dt>
										<dd>{helpLocatorSaid}</dd>
									</div>
									<div>
										<dt>{helpCapability}</dt>
										<dd>{helpCapabilitySaid}</dd>
									</div>
									<div>
										<dt>{helpSwiss}</dt>
										<dd>
											{helpSwissBefore}{" "}
											<button
												id="glossarySecret"
												type="button"
												className="secret-door"
												onPointerEnter={() => prefetch(loadKitchen)}
												onFocus={() => prefetch(loadKitchen)}
												onClick={() => setSink(true)}
											>
												{helpSwissSecret}
											</button>
											{helpSwissAfter}
										</dd>
									</div>
									<div>
										<dt>{helpSturdyref}</dt>
										<dd>{helpSturdyrefSaid}</dd>
									</div>
								</dl>
							</div>
						)}
					<CopyField
						text={document.documentElement.dataset.uiBuild ?? null}
						label={helpCopyBuild}
					/>
				</div>
			</form>
		</dialog>
	);
});
