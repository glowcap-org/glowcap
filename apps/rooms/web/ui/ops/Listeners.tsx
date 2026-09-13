// The listeners pane of the Operations page, drawn only while this tab
// holds the capability (the Capabilities toggle is how it is taken).
//
// The pane knows nothing about transports: the server's own list carries
// each seat's name, description, reference page, live state, and the knobs
// its `up` accepts, so one row template renders whatever the server offers.
// The server admits one live listener per transport, and the switch is the
// whole verb: on brings that listener up with whatever knob fields the
// reader filled in, off takes it down. A seat that is up carries its
// copyable locator, the line an operator hands to whoever should dial it; a
// seat that is down draws one labeled field per knob, each blank field
// meaning the default the server's own hint names. The listener serving this
// very page wears a teal mark and a disabled switch, because taking it down
// would cut off the page and the admin session asking; a seat the server
// already knows cannot come up says why and disables the same way. A refusal
// lands in the row that asked, as the server's own sentence.

import { useState } from "react";
import {
	listenerBringUp,
	listenerCopyLocator,
	listenersLead,
	listenerTakeDown,
	opsListenerServingThisPage,
} from "../../../lib/text/ops.ts";
import { useRoomsSession } from "../controller/session.ts";
import { CopyField } from "../Copy.tsx";
import { Field } from "../Field.tsx";
import { Said } from "../Said.tsx";
import { Switch } from "../Switch.tsx";
import { identifierField } from "../field.ts";
import type { ListenerRow } from "../types.ts";
import { OpsHead } from "./Head.tsx";
import { actionRefusal } from "../error_text.ts";

/** This page's own relay endpoint, which registers rendezvous peers at
 * `/register` beside it — the natural relay for this server to ride, so a
 * `url` knob the server has no default for starts on it. */
function pageRelayUrl(): string {
	const proto = location.protocol === "https:" ? "wss://" : "ws://";
	return `${proto}${location.host}/relay`;
}

/** Whether the server named a real default for this knob: a hint that is a
 * value gets a blank field meaning it, while an empty hint means the knob
 * has nothing to fall back to. */
function knobStartValue(kind: string, hint: string): string {
	return kind === "url" && hint === "" ? pageRelayUrl() : "";
}

export function ListenersPane({ rows }: { rows: readonly ListenerRow[] | null }) {
	const session = useRoomsSession();
	/** Every transport whose verb is in flight, so each switch remains parked
	 * until its own answer lands even when another row is asked meanwhile. */
	const [busyOn, setBusyOn] = useState<ReadonlySet<string>>(() => new Set());
	/** The last refusal per transport, each shown in the row that asked. */
	const [refused, setRefused] = useState<Partial<Record<string, string>>>({});
	/** Edits to the knob fields, keyed `transport/name`; an untouched field
	 * shows its start value. */
	const [fields, setFields] = useState<Partial<Record<string, string>>>({});

	// The modal draws one pane per held capability, so an unheld pane is never
	// asked for; a race with a reconnect's drop simply draws nothing for the
	// one render before the modal follows.
	if (rows === null) return null;

	const fieldValue = (row: ListenerRow, name: string, kind: string, hint: string): string =>
		fields[`${row.transport}/${name}`] ?? knobStartValue(kind, hint);

	const flip = (row: ListenerRow) => {
		setRefused((prior) => ({ ...prior, [row.transport]: undefined }));
		// The id the row carried when this was pressed, not whatever the row
		// carries when the call actually runs. Reading `row.id` inside the
		// callback would follow a later refresh to a different listener, or to
		// null; a type-check refusal is how that showed up.
		const id = row.id;
		if (id !== null) {
			setBusyOn((prior) => new Set(prior).add(row.transport));
			void actionRefusal(() => session.listenerDown(id)).then((why) => {
				setBusyOn((prior) => {
					const next = new Set(prior);
					next.delete(row.transport);
					return next;
				});
				if (why !== "") setRefused((prior) => ({ ...prior, [row.transport]: why }));
			});
			return;
		}
		// Collect the filled knobs; a blank field is the server's own default.
		const options: Record<string, string | number> = {};
		for (const knob of row.takes) {
			const value = fieldValue(row, knob.name, knob.kind, knob.hint);
			if (value === "") continue;
			if (knob.kind === "port") {
				const port = Number(value);
				if (!Number.isInteger(port) || port < 0 || port > 65535) {
					setRefused((prior) => ({
						...prior,
						[row.transport]: `${knob.name} is a whole number between 0 and 65535`,
					}));
					return;
				}
				options[knob.name] = port;
			} else {
				options[knob.name] = value;
			}
		}
		setBusyOn((prior) => new Set(prior).add(row.transport));
		void actionRefusal(() =>
			session.listenerUp(row.transport, Object.keys(options).length === 0 ? undefined : options)
		)
			.then((why) => {
				setBusyOn((prior) => {
					const next = new Set(prior);
					next.delete(row.transport);
					return next;
				});
				if (why !== "") setRefused((prior) => ({ ...prior, [row.transport]: why }));
			});
	};

	return (
		<div className="ops-pane">
			<OpsHead refresh={() => session.refreshOpsCap("listeners")}>{listenersLead}</OpsHead>
			<ul id="listenersList" className="entries ops-tiles">
				{rows.map((row) => {
					const up = row.id !== null;
					const idle = row.unavailable !== "" && !up;
					const why = refused[row.transport];
					return (
						<li
							key={row.transport}
							className="entry well"
							data-transport={row.transport}
							data-up={String(up)}
							data-idle={idle ? "true" : undefined}
						>
							<div className="entry-head">
								<span className="entry-name" id={`listenerName-${row.transport}`}>
									{row.transport}
								</span>
								{
									/* The serving listener carries this very page (and the
									    admin session with it), so its switch is disabled and
									    the mark says why an off is not on offer. */
								}
								{row.serving && (
									<span
										className="ops-serving"
										data-serving="true"
										title={opsListenerServingThisPage}
									>
										this page
									</span>
								)}
								<Switch
									id={`listenerSwitch-${row.transport}`}
									checked={up}
									label={up ? listenerTakeDown(row.transport) : listenerBringUp(row.transport)}
									disabled={row.serving || idle}
									busy={busyOn.has(row.transport)}
									title={row.serving
										? opsListenerServingThisPage
										: idle
										? row.unavailable
										: undefined}
									onClick={() => flip(row)}
								/>
							</div>
							<p className="hint">
								{row.description}
								{row.reference !== "" && (
									<>
										{" "}
										<a href={row.reference} target="_blank" rel="noreferrer">
											about {row.referenceName}
										</a>
									</>
								)}
							</p>
							{idle && <p className="hint ops-idle">{row.unavailable}</p>}
							{up && row.locator !== null && (
								<CopyField
									text={row.locator}
									label={listenerCopyLocator(row.transport)}
								/>
							)}
							{!up && !idle && row.takes.map((knob) => (
								<Field
									key={knob.name}
									id={`listenerOpt-${row.transport}-${knob.name}`}
									label={knob.name}
									layout="inline"
									width={knob.kind === "port" ? "short" : "medium"}
								>
									{(wiring) => (
										<input
											id={wiring.id}
											className="field"
											type="text"
											inputMode={knob.kind === "port"
												? "numeric"
												: knob.kind === "url"
												? "url"
												: "text"}
											enterKeyHint="done"
											value={fieldValue(row, knob.name, knob.kind, knob.hint)}
											disabled={busyOn.has(row.transport)}
											placeholder={knob.hint}
											onChange={(event) =>
												setFields((prior) => ({
													...prior,
													[`${row.transport}/${knob.name}`]: event.target.value,
												}))}
											{...identifierField}
											aria-label={`${knob.name} for the ${row.transport} listener`}
										/>
									)}
								</Field>
							))}
							{why !== undefined && <Said id={`listenerWhy-${row.transport}`} kind="failure">{why}</Said>}
						</li>
					);
				})}
			</ul>
		</div>
	);
}
