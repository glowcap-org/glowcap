// The visualizer pane of the Operations modal, drawn only while this tab
// holds the viz capability (the Advanced toggle is how it is taken).
//
// Two wells, one per question. The first is now: where this tab publishes
// and whether the socket is up this moment. The second is the endpoint
// choice — blank publishes to this page's own server (`/viz`), a WebSocket
// URL points somewhere else — and saving it reloads the window, because the
// tap's endpoint is decided when the peer opens. The timeline itself is
// ocapnviz's screen, not this one.

import { useEffect, useState } from "react";
import { usePeer } from "../peer.ts";
import { advertisedViz, current } from "../prefs.ts";
import { Button } from "../Button.tsx";
import { identifierField } from "../field.ts";
import type { VizPublishState } from "../types.ts";
import { OpsHead } from "./Head.tsx";

export function VizPane({ state }: { state: VizPublishState | null }) {
	const peer = usePeer();
	const [live] = useState(current);
	const [viz, setViz] = useState(live.viz);
	const [hintUrl, setHintUrl] = useState<string | null>(null);
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

	const dirty = viz.trim() !== live.viz.trim();

	return (
		<div className="ops-pane">
			<OpsHead>
				This tab publishes every session it opens, direct messages included, to the live timeline. What leaves
				here is who it talked to and when, never the words. Room messages still show their contents on the
				timeline, published by the room server from its own side. A direct message has no server in the middle,
				so its words go nowhere.
			</OpsHead>
			<div className="group well">
				<table className="ops-table">
					<tbody>
						<tr>
							<td className="ops-kind">Endpoint</td>
							<td>
								<code>{state.url}</code>
							</td>
						</tr>
						<tr>
							<td className="ops-kind">Publishing</td>
							<td id="vizPublishing" data-connected={String(state.connected)}>
								{state.connected ? "on" : "reconnecting…"}
							</td>
						</tr>
					</tbody>
				</table>
			</div>
			<div className="group well" role="group" aria-labelledby="vizLegend">
				<p className="group-label" id="vizLegend">Publish somewhere else</p>
				<input
					id="vizUrl"
					className="field"
					name="viz"
					type="text"
					inputMode="url"
					enterKeyHint="done"
					placeholder={hintUrl ?? "e.g. ws://127.0.0.1:9300/"}
					value={viz}
					onChange={(event) => setViz(event.target.value)}
					{...identifierField}
					aria-labelledby="vizLegend"
					aria-describedby="vizHint"
				/>
				<p id="vizHint" className="hint">
					Leave blank to publish to this page's own endpoint (<code>/viz</code>). Saving reloads this window,
					and the new endpoint asks for its own capability.
				</p>
				<Button
					id="vizUrlSave"
					type="button"
					disabled={!dirty}
					onClick={() => peer.applySettings({ viz })}
				>
					Save and reload
				</Button>
			</div>
		</div>
	);
}
