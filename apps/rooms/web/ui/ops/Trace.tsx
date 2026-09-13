// The visualizer pane of the Operations page, drawn while the session holds
// the trace capability (the Capabilities toggle is how it is taken).
//
// Two wells, one per question. The first is now: where this session publishes
// and whether the socket is up this moment — or the endpoint's own sentence
// when that swiss is dead. The second is the endpoint choice — blank publishes
// to this page's own server (`/trace`), a WebSocket URL points somewhere else —
// and saving it reloads the window, because the tap's endpoint is decided when
// the peer opens. The timeline itself is ocapnviz's screen, not this one.

import { useEffect, useState } from "react";
import {
	traceElsewhereTitle,
	traceEndpointHint,
	traceEndpointLabel,
	traceEndpointSaveRefused,
	traceLead,
	traceNowTitle,
	traceOn,
	tracePublisherShared,
	tracePublisherTab,
	traceReconnecting,
	traceRefused,
} from "../../../lib/text/ops.ts";
import { saveAndReload } from "../../../lib/text/controls.ts";
import { useRoomsController } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { advertisedTrace, current } from "../prefs.ts";
import { traceOverrideRefusal } from "../trace_endpoint.ts";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { Said } from "../Said.tsx";
import type { TracePublishState } from "../types.ts";
import { OpsHead } from "./Head.tsx";
import { SectionTitle } from "./Section.tsx";
import { sharedRoomsSession } from "../../../lib/workspace_view.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { tracePublishing } from "../../../lib/text/ops.ts";

export function TracePane({ state }: { state: TracePublishState | null }) {
	const session = useRoomsSession();
	const controller = useRoomsController();
	const sharedSession = sharedRoomsSession(controller) != null;
	const [live] = useState(current);
	const [trace, setTrace] = useState(live.trace);
	const [hintUrl, setHintUrl] = useState<string | null>(null);
	const [saving, setSaving] = useState(false);
	const [saveWhy, setSaveWhy] = useState("");
	useEffect(() => {
		let cancelled = false;
		void advertisedTrace().then((url) => {
			if (!cancelled) setHintUrl(url);
		});
		return () => {
			cancelled = true;
		};
	}, []);

	// The modal draws one pane per held capability; see the listeners pane.
	if (state === null) return null;

	const dirty = trace !== live.trace;
	const invalid = traceOverrideRefusal(trace);
	const publisher = sharedSession ? tracePublisherShared : tracePublisherTab;

	return (
		<div className="ops-pane">
			<OpsHead>{traceLead(publisher)}</OpsHead>
			<section className="ops-section">
				<SectionTitle id="traceNowLegend">{traceNowTitle}</SectionTitle>
				<div className="group well" role="group" aria-labelledby="traceNowLegend">
					<dl className="dirfacts">
						<dt>{traceEndpointLabel}</dt>
						<dd>
							{state.url}
						</dd>
						<dt>{tracePublishing}</dt>
						<dd
							id="tracePublishing"
							data-connected={String(state.connected)}
							data-refusal={state.refusal ?? undefined}
						>
							{state.connected ? traceOn : state.refusal != null ? traceRefused : traceReconnecting}
						</dd>
					</dl>
					{state.refusal != null && <Said id="traceRefusal" kind="failure">{state.refusal}</Said>}
				</div>
			</section>
			<section className="ops-section">
				<SectionTitle id="traceLegend">{traceElsewhereTitle}</SectionTitle>
				<form
					className="group well"
					role="group"
					aria-labelledby="traceLegend"
					onSubmit={(event) => {
						event.preventDefault();
						if (saving || !dirty || invalid != null) return;
						setSaving(true);
						setSaveWhy("");
						void session.applySettings({ trace }).then((saved) => {
							if (!saved) setSaveWhy(traceEndpointSaveRefused);
						}).catch((error) => setSaveWhy(refusalText(error)))
							.finally(() => setSaving(false));
					}}
				>
					<Field
						id="traceUrl"
						label={traceEndpointLabel}
						width="medium"
						hint={traceEndpointHint}
						said={invalid ?? saveWhy}
					>
						{(wiring) => (
							<input
								id={wiring.id}
								className="field"
								name="trace"
								type="text"
								inputMode="url"
								enterKeyHint="done"
								placeholder={hintUrl ?? "e.g. ws://127.0.0.1:9300/"}
								value={trace}
								disabled={saving}
								onChange={(event) => {
									setTrace(event.target.value);
									setSaveWhy("");
								}}
								{...identifierField}
								aria-describedby={wiring.describedBy}
								aria-invalid={wiring.invalid}
							/>
						)}
					</Field>
					<div className="actions">
						<Button
							id="traceUrlSave"
							type="submit"
							busy={saving}
							disabled={saving || !dirty || invalid != null}
						>
							{saveAndReload}
						</Button>
					</div>
				</form>
			</section>
		</div>
	);
}
