// The peering pane of the Operations page, drawn only while this tab holds
// the capability (the Capabilities toggle is how it is taken).
//
// Publishing is the pane's one act: pick a room this tab has joined on
// another directory, name it, and it becomes a durable room here — listed
// beside the local ones for anyone on this directory to enter, and reached
// through the source's own identity route when they do. The rows below the
// form are this tab's publications, each with the one revocation its lease
// carries. Revoking removes a room from discovery; references already handed
// out stay live, which the destination decides, not this pane. A tab holding
// no other directory has nothing to offer, and the form says so rather than
// drawing an empty picker.

import { useState } from "react";
import { usePeer } from "../peer.ts";
import { Button } from "../Button.tsx";
import { Said } from "../Said.tsx";
import { identifierField } from "../field.ts";
import type { PeeringSource, PeeringState } from "../types.ts";
import { OpsHead } from "./Head.tsx";

export function PeeringPane(
	{ state, sources }: {
		state: PeeringState | null;
		/** The rooms this tab could publish: joined, on a directory other than
		 * this one. Derived above from the conversations, so the choices are
		 * exactly what the tab can reach. */
		sources: readonly PeeringSource[];
	},
) {
	const peer = usePeer();
	const [picked, setPicked] = useState("");
	/** The published name, once the reader has touched it; an untouched field
	 * follows the picked room's own name. */
	const [named, setNamed] = useState<string | null>(null);
	const [publishing, setPublishing] = useState(false);
	const [refused, setRefused] = useState<string | null>(null);
	/** The last refusal per publication row, shown beside the revoke that asked. */
	const [rowRefusals, setRowRefusals] = useState<Partial<Record<number, string>>>({});

	// The modal draws one pane per held capability; see the listeners pane.
	if (state === null) return null;

	const source = sources.find((row) => row.key === picked) ?? sources[0] ?? null;
	const name = named ?? source?.room ?? "";

	const publish = () => {
		if (source === null || name.trim() === "") return;
		setRefused(null);
		setPublishing(true);
		void peer.publishPeeredRoom(source.key, name.trim()).then((why) => {
			setPublishing(false);
			if (why !== "") {
				setRefused(why);
				return;
			}
			setNamed(null);
		});
	};

	const revoke = (id: number) => {
		setRowRefusals((prior) => ({ ...prior, [id]: undefined }));
		void peer.revokePeeredPublication(id).then((why) => {
			if (why !== "") setRowRefusals((prior) => ({ ...prior, [id]: why }));
		});
	};

	return (
		<div className="ops-pane">
			<OpsHead refresh={() => peer.refreshOpsCap("peering")}>
				Publish a room from another directory as a durable listing here, and revoke what this tab published.
			</OpsHead>
			<div className="group well" role="group" aria-labelledby="peeringPublishLabel">
				<p className="group-label" id="peeringPublishLabel">Publish a room</p>
				{sources.length === 0
					? (
						<p className="hint">
							Nothing to publish yet: join a room on another directory first, and it will be offered here.
						</p>
					)
					: (
						<form
							onSubmit={(event) => {
								event.preventDefault();
								publish();
							}}
						>
							{
								/* The select names its own choice — a room, and the directory
							    it lives on — so only the name field carries a written label:
							    what changes here is what this directory will call it. */
							}
							<span className="select-wrap">
								<select
									id="peeringSource"
									className="field"
									value={source?.key ?? ""}
									aria-label="The room to publish, on the directory it lives on"
									onChange={(event) => {
										setPicked(event.target.value);
										setNamed(null);
									}}
								>
									{sources.map((row) => (
										<option key={row.key} value={row.key}>
											{row.room} · on {row.directory}
										</option>
									))}
								</select>
							</span>
							<label className="field-label" htmlFor="peeringName">listed here as</label>
							<input
								id="peeringName"
								className="field"
								type="text"
								enterKeyHint="go"
								value={name}
								onChange={(event) => setNamed(event.target.value)}
								{...identifierField}
								placeholder="what this directory lists it as"
								aria-describedby={refused !== null ? "peeringWhy" : undefined}
								aria-invalid={refused !== null}
							/>
							<p className="hint">
								Anyone on this directory can enter it under that name. The room itself stays where it
								lives.
							</p>
							{refused !== null && <Said id="peeringWhy" kind="failure">{refused}</Said>}
							<Button
								id="peeringPublish"
								type="submit"
								busy={publishing}
								disabled={name.trim() === ""}
							>
								Publish
							</Button>
						</form>
					)}
			</div>
			<div className="group well">
				<p className="group-label">Published by this tab</p>
				{state.publications.length === 0
					? <p className="ops-empty">No rooms published from this tab yet.</p>
					: (
						<ul className="ops-pubs" id="peeringList">
							{state.publications.map((row) => (
								<li key={row.id} className="ops-pub" data-phase={row.phase}>
									<div className="ops-pub-head">
										<span className="ops-pub-name">{row.name}</span>
										{
											/* The row's own word on what is in flight. A busy Revoke
										    while the publish is still landing would announce the
										    wrong act, so publishing shows as a quiet word and the
										    control arrives with the authority it names. */
										}
										{row.phase === "publishing"
											? <span className="hint">publishing…</span>
											: (
												<Button
													type="button"
													variant="quiet"
													busy={row.phase === "revoking"}
													onClick={() => revoke(row.id)}
												>
													Revoke
												</Button>
											)}
									</div>
									<p className="ops-pub-source">
										from <code>{row.source}</code>
									</p>
									{rowRefusals[row.id] !== undefined && (
										<Said id={`peeringRowWhy-${row.id}`} kind="failure">
											{rowRefusals[row.id]}
										</Said>
									)}
								</li>
							))}
						</ul>
					)}
			</div>
		</div>
	);
}
