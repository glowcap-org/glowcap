// The peering pane of the Operations page, drawn only while this tab holds
// the capability (the Capabilities toggle is how it is taken).
//
// Publishing is the pane's one act: pick a room this tab has joined on
// another directory, name it, and it becomes a foreign listing here, shown
// beside the local rooms for anyone on this directory to enter, and reached
// through the source's own identity route when they do. The rows below the
// form are this tab's publications, each with the one revocation its lease
// carries. Revoking removes a room from discovery. References already handed
// out stay live, which the destination decides, not this pane. A tab holding
// no other directory has nothing to offer, and the form says so rather than
// drawing an empty picker.

import { useState } from "react";
import {
	opsPeeringAsLabel,
	opsPeeringRoomLabel,
	peeringAsHint,
	peeringLead,
	peeringListedAs,
	peeringNothingToPublish,
	peeringPublishedEmpty,
	peeringPublishedTitle,
	peeringPublishTitle,
} from "../../../lib/text/ops.ts";
import { useRoomsSession } from "../controller/session.ts";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { Said } from "../Said.tsx";
import { identifierField } from "../field.ts";
import type { PeeringSource, PeeringState } from "../types.ts";
import { OpsHead } from "./Head.tsx";
import { SectionTitle } from "./Section.tsx";
import { actionRefusal } from "../error_text.ts";
import {
	peeringAsPlaceholder,
	peeringPublish,
	peeringPublishing,
	peeringPublishingAction,
} from "../../../lib/text/ops.ts";

export function PeeringPane(
	{ state, sources }: {
		state: PeeringState | null;
		/** Held durable room entrances on another connected directory, derived
		 * from the same custody projection the publish command selects. */
		sources: readonly PeeringSource[];
	},
) {
	const session = useRoomsSession();
	const [picked, setPicked] = useState("");
	/** The published name, once the reader has touched it. An untouched field
	 * follows the picked room's own name. */
	const [named, setNamed] = useState<string | null>(null);
	const [publishing, setPublishing] = useState(false);
	const [published, setPublished] = useState("");
	const [refused, setRefused] = useState<string | null>(null);
	/** The last refusal per publication row, shown beside the revoke that asked. */
	const [rowRefusals, setRowRefusals] = useState<Partial<Record<string, string>>>({});
	const [revoking, setRevoking] = useState<ReadonlySet<string>>(new Set());

	// The modal draws one pane per held capability; see the listeners pane.
	if (state === null) return null;

	const source = sources.find((row) => row.key === picked) ?? sources[0] ?? null;
	const name = named ?? source?.room ?? "";

	const publish = (chosen: PeeringSource | null, entered: string) => {
		const publishedName = entered;
		if (chosen === null || publishedName === "") return;
		setRefused(null);
		setPublished("");
		setPublishing(true);
		void actionRefusal(() => session.publishPeeredRoom(chosen.key, publishedName)).then((why) => {
			setPublishing(false);
			if (why !== "") {
				setRefused(why);
				return;
			}
			setPublished(peeringListedAs(publishedName));
			setNamed(null);
		});
	};

	const revoke = (id: string | number) => {
		const key = String(id);
		if (revoking.has(key)) return;
		setRevoking((prior) => new Set(prior).add(key));
		setRowRefusals((prior) => ({ ...prior, [key]: undefined }));
		void actionRefusal(() => session.revokePeeredPublication(id)).then((why) => {
			if (why !== "") setRowRefusals((prior) => ({ ...prior, [key]: why }));
		}).finally(() =>
			setRevoking((prior) => {
				const next = new Set(prior);
				next.delete(key);
				return next;
			})
		);
	};

	return (
		<div className="ops-pane">
			<OpsHead refresh={() => session.refreshOpsCap("peering")}>{peeringLead}</OpsHead>
			<section className="ops-section">
				<SectionTitle id="peeringPublishLabel">{peeringPublishTitle}</SectionTitle>
				<div className="group well" role="group" aria-labelledby="peeringPublishLabel">
					{sources.length === 0 ? <p className="empty">{peeringNothingToPublish}</p> : (
						<form
							className="group"
							onSubmit={(event) => {
								event.preventDefault();
								// The submitted controls are authoritative. Reading the
								// rendered-state closure here can lag a very fast type-and-submit
								// sequence by one React commit and publish the previous name.
								const submitted = new FormData(event.currentTarget);
								const sourceKey = String(submitted.get("source") ?? "");
								const chosen = sources.find((row) => row.key === sourceKey) ?? null;
								publish(chosen, String(submitted.get("name") ?? ""));
							}}
						>
							<Field id="peeringSource" label={opsPeeringRoomLabel}>
								{(wiring) => (
									<span className="select-wrap">
										<select
											id={wiring.id}
											name="source"
											className="field"
											value={source?.key ?? ""}
											disabled={publishing}
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
								)}
							</Field>
							<Field
								id="peeringName"
								label={opsPeeringAsLabel}
								hint={peeringAsHint}
								said={refused ?? ""}
							>
								{(wiring) => (
									<input
										id={wiring.id}
										name="name"
										className="field"
										type="text"
										enterKeyHint="go"
										value={name}
										disabled={publishing}
										onChange={(event) => setNamed(event.target.value)}
										{...identifierField}
										placeholder={peeringAsPlaceholder}
										aria-describedby={wiring.describedBy}
										aria-invalid={wiring.invalid}
									/>
								)}
							</Field>
							<div className="actions">
								<Button
									id="peeringPublish"
									type="submit"
									busy={publishing}
									disabled={name === ""}
								>
									{publishing ? peeringPublishingAction : peeringPublish}
								</Button>
							</div>
							{published !== "" && <Said kind="success">{published}</Said>}
						</form>
					)}
				</div>
			</section>
			<section className="ops-section">
				<SectionTitle id="peeringListLabel">{peeringPublishedTitle}</SectionTitle>
				<div className="group well" role="group" aria-labelledby="peeringListLabel">
					{state.publications.length === 0
						? <p className="empty">{peeringPublishedEmpty}</p>
						: (
							<ul className="entries" id="peeringList">
								{state.publications.map((row) => (
									<li key={row.id} className="entry" data-phase={row.phase}>
										<div className="entry-head">
											<span className="entry-name">{row.name}</span>
											{
												/* The row's own word on what is in flight. A busy Revoke
										    while the publish is still landing would announce the
										    wrong act, so publishing shows as a quiet word and the
										    control arrives with the authority it names. */
											}
											{row.phase === "publishing"
												? <span className="entry-meta">{peeringPublishing}</span>
												: (
													<div className="actions">
														<Button
															type="button"
															variant="quiet"
															busy={row.phase === "revoking" ||
																revoking.has(String(row.id))}
															disabled={revoking.has(String(row.id))}
															onClick={() => revoke(row.id)}
														>
															Revoke
														</Button>
													</div>
												)}
										</div>
										<p className="entry-meta">
											from {row.source}
										</p>
										{rowRefusals[String(row.id)] != null && (
											<Said id={`peeringRowWhy-${row.id}`} kind="failure">
												{rowRefusals[String(row.id)]}
											</Said>
										)}
									</li>
								))}
							</ul>
						)}
				</div>
			</section>
		</div>
	);
}
