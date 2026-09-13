import { useEffect } from "react";
import { useLocation } from "react-router";
import { Button } from "../Button.tsx";
import { CopyField } from "../Copy.tsx";
import { Said } from "../Said.tsx";
import { useRoomsSession } from "../controller/session.ts";
import type { OperatorCategory, RoomsOperatorState } from "../types.ts";
import type { OperatorResetScope } from "../../../lib/operator.ts";
import { OpsHead } from "./Head.tsx";
import { OperatorReferences, referencesFilterKey } from "./OperatorReferences.tsx";
import { useOperatorActs } from "./operator_acts.tsx";
import { SectionTitle } from "./Section.tsx";
import { OperatorSearch } from "./OperatorSearch.tsx";
import { OperatorSweep } from "./OperatorSweep.tsx";
import { OperatorActivityProvider } from "./operator_activity.tsx";
import {
	operatorCopyModerator,
	operatorDisconnectAsk,
	operatorGranting,
	operatorGrantModerator,
	operatorLead,
	operatorLinkRemove,
	operatorLinkRemoveEffect,
	operatorLinksEmpty,
	operatorLinksLead,
	operatorLinksSweepEffect,
	operatorLinksSweepSubject,
	operatorLinksTitle,
	operatorLoadMore,
	operatorModerationEmpty,
	operatorModerationLead,
	operatorModerationTitle,
	operatorModeratorRevoke,
	operatorModeratorRevokeEffect,
	operatorNamesEmpty,
	operatorNamesLead,
	operatorNamesSweepEffect,
	operatorNamesSweepSubject,
	operatorNamesTitle,
	operatorNickRemove,
	operatorNickRemoveEffect,
	operatorPrivateRoom,
	operatorProofAuthenticated,
	operatorProofBridge,
	operatorProofSession,
	operatorRemoveAsk,
	type OperatorReset,
	operatorResetAll,
	operatorResetLead,
	operatorResetLinks,
	operatorResetRegistrations,
	operatorResetRooms,
	operatorResetRuntime,
	operatorResetSessions,
	operatorResetTitle,
	operatorRoomFrom,
	operatorRoomKind,
	operatorRoomRemoveAct,
	operatorRoomRetains,
	operatorRoomsEmpty,
	operatorRoomsLead,
	operatorRoomsSweepEffect,
	operatorRoomsSweepSubject,
	operatorRoomsTitle,
	operatorRoomWith,
	operatorRotateAsk,
	operatorSessionDisconnect,
	operatorSessionDisconnectEffect,
	operatorSessionsEmpty,
	operatorSessionsLead,
	operatorSessionsSweepEffect,
	operatorSessionsSweepSubject,
	operatorSessionsTitle,
	operatorSweepDisconnect,
	operatorSweepDisconnected,
	operatorSweepRemove,
	operatorSweepRemoved,
	operatorSweepRevoke,
	operatorSweepRevoked,
	operatorTroubleClear,
	operatorTroubleClearAsk,
	operatorTroubleClearEffect,
	operatorTroubleEmpty,
	operatorTroubleLead,
	operatorTroubleTitle,
	operatorUnnamedPeer,
	operatorUnnamedPrivateRoom,
	operatorYours,
} from "../../../lib/text/operator.ts";

const OPERATOR_RESETS: readonly ({ scope: OperatorResetScope } & OperatorReset)[] = [
	{ scope: "links", ...operatorResetLinks },
	{ scope: "registrations", ...operatorResetRegistrations },
	{ scope: "sessions", ...operatorResetSessions },
	{ scope: "rooms", ...operatorResetRooms },
	{ scope: "runtime", ...operatorResetRuntime },
	{ scope: "all", ...operatorResetAll },
];

/** What a room row is, and how its origin is known.
 *
 * These are two facts, and one of them is about trust: an authenticated origin
 * proved the publisher's durable identity, while a session origin proved only
 * which connection carried it. They were drawn as `kind · proof`, two bare
 * words either side of a middot, which for a local room read "local · local"
 * and said nothing twice.
 *
 * A local room's origin is forced to `local` by the server, so it restates the
 * kind and is left out rather than drawn as a second chip saying the same
 * word. */
const ROOM_PROOF_FACE: Readonly<Record<string, { label: string; tone?: "quiet" | "warn" }>> = {
	authenticated: { label: operatorProofAuthenticated },
	session: { label: operatorProofSession, tone: "warn" },
	bridge: { label: operatorProofBridge, tone: "quiet" },
};

export function OperatorPane({ state }: { state: RoomsOperatorState | null }) {
	return (
		<OperatorActivityProvider>
			<OperatorPaneContent state={state} />
		</OperatorActivityProvider>
	);
}

function OperatorPaneContent({ state }: { state: RoomsOperatorState | null }) {
	const session = useRoomsSession();
	const acts = useOperatorActs();
	const location = useLocation();
	useEffect(() => {
		if (state == null) return;
		const id = location.hash.startsWith("#") ? location.hash.slice(1) : "";
		if (id !== "") document.getElementById(id)?.scrollIntoView({ block: "start" });
	}, [location.hash, state]);
	if (state == null) return null;
	const more = (category: OperatorCategory) =>
		state.next[category] != null && (
			<div className="actions">
				<Button
					variant="quiet"
					busy={acts.busy(`more:${category}`)}
					onClick={() => acts.run(`more:${category}`, () => session.loadMoreOperator(category))}
				>
					{operatorLoadMore}
				</Button>
			</div>
		);
	return (
		<div className="ops-pane">
			<OpsHead refresh={() => session.refreshOpsCap("operator")}>{operatorLead}</OpsHead>
			<OperatorSearch search={state.search} referenceKind={state.referenceKind} />
			<section className="ops-section" id="operatorRoomLinks">
				<SectionTitle count={state.totals.links}>{operatorLinksTitle}</SectionTitle>
				<div className="group well">
					<p className="hint">{operatorLinksLead}</p>
					{state.links.length === 0 ? <p className="empty">{operatorLinksEmpty}</p> : (
						<ul className="entries">
							{state.links.map((row) => {
								const key = `link:${row.name}`;
								return (
									<li className="entry" key={row.name}>
										<div className="entry-head" data-one-line>
											<span className="entry-name">{row.label || operatorPrivateRoom}</span>
											<span className="tag" data-tone="quiet">{row.visibility}</span>
											<div className="actions">
												<Button
													variant="quiet"
													disabled={acts.confirming === key}
													onClick={() => acts.ask(key)}
												>
													{operatorRemoveAsk}
												</Button>
											</div>
										</div>
										{acts.confirm(
											key,
											operatorLinkRemoveEffect,
											operatorLinkRemove,
											() => session.revokeRoomLink(row.name),
										)}
										{acts.why[key] != null && <Said kind="failure">{acts.why[key]}</Said>}
									</li>
								);
							})}
						</ul>
					)}
					{more("links")}
					<OperatorSweep
						category="links"
						act={operatorSweepRevoke}
						past={operatorSweepRevoked}
						subject={operatorLinksSweepSubject}
						effect={operatorLinksSweepEffect}
						search={state.search}
						total={state.totals.links}
					/>
				</div>
			</section>
			<section className="ops-section" id="operatorNames">
				<SectionTitle count={state.totals.registrations}>{operatorNamesTitle}</SectionTitle>
				<div className="group well">
					<p className="hint">{operatorNamesLead}</p>
					{state.registrations.length === 0
						? <p className="empty">{operatorNamesEmpty}</p>
						: (
							<ul className="entries">
								{state.registrations.map((row) => {
									const key = `nick:${row.sessionId}:${row.nick}`;
									return (
										<li className="entry" key={key}>
											<div className="entry-head" data-one-line>
												<span className="entry-name">{row.nick}</span>
												{row.sessionId.slice(0, 8)}
												{
													/* The answer to "which session is that": when the
												    holder is the very connection this operator view
												    reads the directory through, say so, because a
												    holder the sessions list hid read as a leak. */
												}
												{row.you && (
													<span className="tag" data-tone="quiet">{operatorYours}</span>
												)}
												<div className="actions">
													<Button
														variant="quiet"
														disabled={acts.confirming === key}
														onClick={() => acts.ask(key)}
													>
														{operatorRemoveAsk}
													</Button>
												</div>
											</div>
											{acts.confirm(
												key,
												operatorNickRemoveEffect,
												operatorNickRemove,
												() => session.revokeNick(row.nick, row.sessionId),
											)}
											{acts.why[key] != null && <Said kind="failure">{acts.why[key]}</Said>}
										</li>
									);
								})}
							</ul>
						)}
					{more("registrations")}
					<OperatorSweep
						category="registrations"
						act={operatorSweepRemove}
						past={operatorSweepRemoved}
						subject={operatorNamesSweepSubject}
						effect={operatorNamesSweepEffect}
						search={state.search}
						total={state.totals.registrations}
					/>
				</div>
			</section>
			<section className="ops-section" id="operatorSessions">
				<SectionTitle count={state.totals.sessions}>{operatorSessionsTitle}</SectionTitle>
				<div className="group well">
					<p className="hint">{operatorSessionsLead}</p>
					{state.sessions.length === 0
						? <p className="empty">{operatorSessionsEmpty}</p>
						: (
							<ul className="entries">
								{state.sessions.map((row) => {
									const key = `session:${row.id}`;
									return (
										<li className="entry" key={row.id}>
											<div className="entry-head" data-one-line>
												<span className="entry-name">{row.nick || operatorUnnamedPeer}</span>
												<span className="tag" data-tone="quiet">{row.transport}</span>
												{
													/* The same eight characters, in the same clothes, as the
												    name rows above: it is what ties a registered nickname
												    to the connection holding it. */
												}
												{row.id.slice(0, 8)}
												{row.you && (
													<span className="tag" data-tone="quiet">{operatorYours}</span>
												)}
												{
													/* No disconnect on your own connection: the server
												    refuses it, and a control that can only refuse is
												    not offered. */
												}
												<div className="actions">
													{!row.you && (
														<Button
															variant="quiet"
															disabled={acts.confirming === key}
															onClick={() => acts.ask(key)}
														>
															{operatorDisconnectAsk}
														</Button>
													)}
												</div>
											</div>
											{acts.confirm(
												key,
												operatorSessionDisconnectEffect,
												operatorSessionDisconnect,
												() => session.disconnectSession(row.id),
											)}
											{acts.why[key] != null && <Said kind="failure">{acts.why[key]}</Said>}
										</li>
									);
								})}
							</ul>
						)}
					{more("sessions")}
					<OperatorSweep
						category="sessions"
						act={operatorSweepDisconnect}
						past={operatorSweepDisconnected}
						subject={operatorSessionsSweepSubject}
						effect={operatorSessionsSweepEffect}
						search={state.search}
						total={state.totals.sessions}
					/>
				</div>
			</section>
			<section className="ops-section" id="operatorRooms">
				<SectionTitle count={state.totals.rooms}>{operatorRoomsTitle}</SectionTitle>
				<div className="group well">
					<p className="hint">{operatorRoomsLead}</p>
					{state.rooms.length === 0 ? <p className="empty">{operatorRoomsEmpty}</p> : (
						<ul className="entries">
							{state.rooms.map((row) => {
								const key = `room:${row.id}`;
								const proof = ROOM_PROOF_FACE[row.proof];
								const { action, effect } = operatorRoomRemoveAct(row.kind);
								return (
									<li className="entry" key={row.id} data-kind={row.kind}>
										<div className="entry-head" data-one-line>
											<span className="entry-name">
												{row.name || operatorUnnamedPrivateRoom}
											</span>
											<span className="tag" data-tone="quiet">
												{operatorRoomKind[row.kind] ?? row.kind}
											</span>
											{proof != null && (
												<span className="tag" data-tone={proof.tone}>{proof.label}</span>
											)}
											<div className="actions">
												<Button
													variant="quiet"
													disabled={acts.confirming === key}
													onClick={() => acts.ask(key)}
												>
													{action}…
												</Button>
											</div>
										</div>
										{row.origin !== "" && (
											<p className="entry-meta">{operatorRoomFrom(row.origin)}</p>
										)}
										{row.retainedCapabilities !== null && (
											<p className="entry-meta">
												{operatorRoomRetains(row.retainedCapabilities)}
											</p>
										)}
										{row.members.length > 0 && (
											<p className="entry-meta">{operatorRoomWith(row.members)}</p>
										)}
										{acts.confirm(key, effect, action, () => session.removeOperatorRoom(row.id))}
										{acts.why[key] != null && <Said kind="failure">{acts.why[key]}</Said>}
									</li>
								);
							})}
						</ul>
					)}
					{more("rooms")}
					<OperatorSweep
						category="rooms"
						act={operatorSweepRemove}
						past={operatorSweepRemoved}
						subject={operatorRoomsSweepSubject}
						effect={operatorRoomsSweepEffect}
						search={state.search}
						total={state.totals.rooms}
					/>
				</div>
			</section>
			<OperatorReferences
				rows={state.references}
				total={state.totals.references}
				search={state.search}
				referenceKind={state.referenceKind}
				// Use the pane's own acts, as every other press here does: this marks
				// the filter busy and keeps the refusal. The
				// bare call beside it drew nothing and said nothing, while the
				// search box above ran the same verb with a wait, an answer, and a
				// guard against a stale one landing late.
				onFilter={(kind) => acts.run(referencesFilterKey, () => session.searchOperator("", kind))}
				acts={acts}
				more={more("references")}
			/>
			<section className="ops-section" id="operatorRoomModeration">
				<SectionTitle
					id="roomModerationTitle"
					count={state.totals.stewardships}
				>
					{operatorModerationTitle}
				</SectionTitle>
				<div className="group well" id="roomModerationCapabilities">
					<p className="hint">{operatorModerationLead}</p>
					{state.stewardships.length === 0
						? <p className="empty">{operatorModerationEmpty}</p>
						: (
							<ul className="entries">
								{state.stewardships.map((row) => {
									const title = row.label || operatorPrivateRoom;
									const key = `moderator:${row.name}`;
									return (
										<li className="entry" key={row.name} data-room={row.name}>
											<div className="entry-head" data-one-line>
												<span className="entry-name">{title}</span>
												<span className="tag" data-tone="quiet">{row.visibility}</span>
												<div className="actions">
													{row.issued
														? (
															<Button
																variant="quiet"
																disabled={acts.confirming === key}
																onClick={() => acts.ask(key)}
															>
																{operatorRotateAsk}
															</Button>
														)
														: (
															<Button
																busy={acts.busy(key)}
																onClick={() =>
																	acts.run(
																		key,
																		() => session.giveRoomStewardship(row.name),
																	)}
															>
																{acts.busy(key)
																	? operatorGranting
																	: operatorGrantModerator}
															</Button>
														)}
												</div>
											</div>
											{row.stewardLink !== null && (
												<CopyField
													compact
													text={row.stewardLink}
													label={operatorCopyModerator(title)}
												/>
											)}
											{acts.confirm(
												key,
												operatorModeratorRevokeEffect,
												operatorModeratorRevoke,
												() => session.revokeRoomStewardship(row.name),
											)}
											{acts.why[key] != null && <Said kind="failure">{acts.why[key]}</Said>}
										</li>
									);
								})}
							</ul>
						)}
					{more("stewardships")}
				</div>
			</section>
			<section className="ops-section" id="operatorTrouble">
				<SectionTitle count={state.totals.trouble}>
					{operatorTroubleTitle}
				</SectionTitle>
				<div className="group well">
					<p className="hint">{operatorTroubleLead}</p>
					{state.trouble.length === 0 ? <p className="empty">{operatorTroubleEmpty}</p> : (
						<>
							<ul className="ops-trouble">
								{state.trouble.map((row, at) => (
									<li key={`${row.source}:${row.reason}:${at}`}>
										<span className="ops-kind">{row.source}</span>
										<span className="entry-meta ops-note">{row.reason}</span>
										{row.count > 1 && <span className="ops-trouble-count">×{row.count}</span>}
									</li>
								))}
							</ul>
							<div className="actions">
								<Button
									variant="quiet"
									disabled={acts.confirming === "trouble:all"}
									onClick={() => acts.ask("trouble:all")}
								>
									{operatorTroubleClearAsk}
								</Button>
							</div>
							{acts.confirm(
								"trouble:all",
								operatorTroubleClearEffect,
								operatorTroubleClear,
								() => session.clearOperatorTrouble(),
							)}
							{acts.why["trouble:all"] != null && <Said kind="failure">{acts.why["trouble:all"]}</Said>}
						</>
					)}
					{more("trouble")}
				</div>
			</section>
			<section className="ops-section" id="operatorReset">
				<SectionTitle>{operatorResetTitle}</SectionTitle>
				<div className="group well">
					<p className="hint">{operatorResetLead}</p>
					<ul className="entries ops-two-up">
						{OPERATOR_RESETS.map(({ scope, subject, act, label, effect }) => {
							const key = `reset:${scope}`;
							return (
								<li className="entry" key={scope}>
									<div className="entry-head">
										<span className="entry-name">{subject}</span>
										<div className="actions">
											<Button
												variant="quiet"
												disabled={acts.confirming === key}
												aria-label={label + "…"}
												onClick={() => acts.ask(key)}
											>
												{act}…
											</Button>
										</div>
									</div>
									{acts.confirm(
										key,
										effect,
										label,
										() => session.resetOperatorScope(scope),
									)}
									{acts.why[key] != null && <Said kind="failure">{acts.why[key]}</Said>}
								</li>
							);
						})}
					</ul>
				</div>
			</section>
		</div>
	);
}
