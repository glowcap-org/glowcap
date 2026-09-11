// The visualizer pane of the Operations page, drawn while the session holds
// the viz capability (the Capabilities toggle is how it is taken).
//
// Two wells, one per question. The first is now: where this session publishes
// and whether the socket is up this moment — or the endpoint's own sentence
// when that swiss is dead. The second is the endpoint choice — blank publishes
// to this page's own server (`/viz`), a WebSocket URL points somewhere else —
// and saving it reloads the window, because the tap's endpoint is decided when
// the peer opens. The timeline itself is ocapnviz's screen, not this one.

import { useEffect, useState } from "react";
import { useRoomsController } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { advertisedViz, current } from "../prefs.ts";
import { vizOverrideRefusal } from "../viz_endpoint.ts";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { Said } from "../Said.tsx";
import type { VizPublishState } from "../types.ts";
import { OpsHead } from "./Head.tsx";
import { SectionTitle } from "./Section.tsx";
import { sharedRoomsSession } from "../../../lib/workspace_view.ts";

export function VizPane({ state }: { state: VizPublishState | null }) {
	const session = useRoomsSession();
	const sharedSession = sharedRoomsSession(useRoomsController()) != null;
	const [live] = useState(current);
	const [viz, setViz] = useState(live.viz);
	const [hintUrl, setHintUrl] = useState<string | null>(null);
	const [saving, setSaving] = useState(false);
	const [saveWhy, setSaveWhy] = useState("");
	useEffect(() => {
		let cancelled = false;
		void advertisedViz().then((url) => {
			if (!cancelled) setHintUrl(url);
		});
		return () => {
			cancelled = true;
		};
	}, []);

	// The modal draws one pane per held capability; see the listeners pane.
	if (state === null) return null;

	const dirty = viz !== live.viz;
	const invalid = vizOverrideRefusal(viz);
	const publisher = sharedSession
		? "The shared session publishes every connection it opens"
		: "This tab publishes every session it opens";

	return (
		<div className="ops-pane">
			<OpsHead>
				{publisher}, direct messages included, to the live timeline. What leaves here is who it talked to and
				when, never the words. Room messages still show their contents on the timeline, published by the room
				server from its own side. A direct message has no server in the middle, so its words go nowhere.
			</OpsHead>
			<section className="ops-section">
				<SectionTitle id="vizNowLegend">Publishing now</SectionTitle>
				<div className="group well" role="group" aria-labelledby="vizNowLegend">
					<dl className="dirfacts">
						<dt>Endpoint</dt>
						<dd>
							{state.url}
						</dd>
						<dt>Publishing</dt>
						<dd
							id="vizPublishing"
							data-connected={String(state.connected)}
							data-refusal={state.refusal ?? undefined}
						>
							{state.connected ? "on" : state.refusal != null ? "refused" : "reconnecting…"}
						</dd>
					</dl>
					{state.refusal != null && <Said id="vizRefusal" kind="failure">{state.refusal}</Said>}
				</div>
			</section>
			<section className="ops-section">
				<SectionTitle id="vizLegend">Publish somewhere else</SectionTitle>
				<form
					className="group well"
					role="group"
					aria-labelledby="vizLegend"
					onSubmit={(event) => {
						event.preventDefault();
						if (saving || !dirty || invalid != null) return;
						setSaving(true);
						setSaveWhy("");
						void session.applySettings({ viz }).then((saved) => {
							if (!saved) setSaveWhy("This browser could not save the visualizer endpoint.");
						}).finally(() => setSaving(false));
					}}
				>
					<Field
						id="vizUrl"
						label="Endpoint"
						width="medium"
						hint={
							<>
								Leave blank to publish to this page's own endpoint (/viz). Saving reloads this window,
								and the new endpoint asks for its own capability.
							</>
						}
						said={invalid ?? saveWhy}
					>
						{(wiring) => (
							<input
								id={wiring.id}
								className="field"
								name="viz"
								type="text"
								inputMode="url"
								enterKeyHint="done"
								placeholder={hintUrl ?? "e.g. ws://127.0.0.1:9300/"}
								value={viz}
								disabled={saving}
								onChange={(event) => {
									setViz(event.target.value);
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
							id="vizUrlSave"
							type="submit"
							busy={saving}
							disabled={saving || !dirty || invalid != null}
						>
							Save and reload
						</Button>
					</div>
				</form>
			</section>
		</div>
	);
}
