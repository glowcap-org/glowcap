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

const OPERATOR_RESETS: readonly {
	scope: OperatorResetScope;
	/** What the reset is about, in the row's name. */
	subject: string;
	/** The act, offered with an ellipsis and committed in full. */
	act: string;
	label: string;
	effect: string;
}[] = [
	{
		scope: "links",
		subject: "Room entry links",
		act: "Revoke all",
		label: "Revoke all room entry links",
		effect: "Every current durable room entry link is permanently revoked.",
	},
	{
		scope: "registrations",
		subject: "Nickname claims",
		act: "Reset",
		label: "Reset nickname claims",
		effect: "Every current nickname registration, voucher, inbox offer, and signaling route is retired.",
	},
	{
		scope: "sessions",
		subject: "Other peer sessions",
		act: "Disconnect",
		label: "Disconnect other peer sessions",
		effect: "Every peer session except this operator connection is disconnected.",
	},
	{
		scope: "rooms",
		subject: "Rooms",
		act: "Remove all",
		label: "Remove all rooms",
		effect: "Every current room owner and the capability occurrences it retains are removed.",
	},
	{
		scope: "runtime",
		subject: "Directory runtime",
		act: "Reset",
		label: "Reset directory runtime",
		effect:
			"All rooms, nickname claims, other peer sessions, and current trouble are retired. Durable room entry links and server identity remain.",
	},
	{
		scope: "all",
		subject: "Rooms authority",
		act: "Factory reset",
		label: "Factory reset Rooms authority",
		effect:
			"The room-authority secret is rotated. Active links, tombstones, and moderator grants are cleared, and then all rooms, nickname claims, other peer sessions, and current trouble are retired. This operator connection, server identity, and retained message history remain. Old authorities stay revoked, and room names can mint unrelated new links.",
	},
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
const ROOM_KIND_LABEL: Readonly<Record<string, string>> = {
	local: "local",
	private: "private",
	peered: "peered",
	"pending-peered": "pending",
	irc: "IRC",
};

const ROOM_PROOF_FACE: Readonly<Record<string, { label: string; tone?: "quiet" | "warn" }>> = {
	authenticated: { label: "identity proved" },
	session: { label: "session only", tone: "warn" },
	bridge: { label: "through the bridge", tone: "quiet" },
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
					Load more
				</Button>
			</div>
		);
	return (
		<div className="ops-pane">
			<OpsHead refresh={() => session.refreshOpsCap("operator")}>
				This tab holds the Rooms operator capability. Its inventories are the state it can change, not roles
				inferred from a nickname or room membership.
			</OpsHead>
			<OperatorSearch search={state.search} referenceKind={state.referenceKind} />
			<section className="ops-section" id="operatorRoomLinks">
				<SectionTitle count={state.totals.links}>Room access</SectionTitle>
				<div className="group well">
					<p className="hint">
						Durable room entry links admit future holders and already-live copies. Removing one invalidates
						both.
					</p>
					{state.links.length === 0
						? <p className="empty">No durable room entry links are active.</p>
						: (
							<ul className="entries">
								{state.links.map((row) => {
									const key = `link:${row.name}`;
									return (
										<li className="entry" key={row.name}>
											<div className="entry-head" data-one-line>
												<span className="entry-name">{row.label || "Private room"}</span>
												<span className="tag" data-tone="quiet">{row.visibility}</span>
												<div className="actions">
													<Button
														variant="quiet"
														disabled={acts.confirming === key}
														onClick={() => acts.ask(key)}
													>
														Remove…
													</Button>
												</div>
											</div>
											{acts.confirm(
												key,
												"Copied links and references already in use stop opening this room. A later link for the same room will be a fresh capability.",
												"Remove room entry link",
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
						act="Revoke"
						past="Revoked"
						subject="room entry links"
						effect="Copied links and references already in use stop opening those rooms. Later links for the same rooms will be fresh capabilities."
						search={state.search}
						total={state.totals.links}
					/>
				</div>
			</section>
			<section className="ops-section" id="operatorNames">
				<SectionTitle count={state.totals.registrations}>
					Names and reachability
				</SectionTitle>
				<div className="group well">
					<p className="hint">
						A registered nickname holds direct-message inboxes and signaling routes on one exact session.
					</p>
					{state.registrations.length === 0
						? <p className="empty">No nicknames are registered.</p>
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
												{row.you && <span className="tag" data-tone="quiet">yours</span>}
												<div className="actions">
													<Button
														variant="quiet"
														disabled={acts.confirming === key}
														onClick={() => acts.ask(key)}
													>
														Remove…
													</Button>
												</div>
											</div>
											{acts.confirm(
												key,
												"The holder loses this name, its vouchers, inbox offers, and directory-routed DM reachability.",
												"Remove nickname claim",
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
						act="Remove"
						past="Removed"
						subject="nickname claims"
						effect="Each holder loses that name, its vouchers, inbox offers, and directory-routed reachability."
						search={state.search}
						total={state.totals.registrations}
					/>
				</div>
			</section>
			<section className="ops-section" id="operatorSessions">
				<SectionTitle count={state.totals.sessions}>
					Connections and live references
				</SectionTitle>
				<div className="group well">
					<p className="hint">
						Disconnecting retires the session's memberships, registrations, imports, exports, and object
						references together.
					</p>
					{state.sessions.length === 0
						? <p className="empty">No peer sessions are connected.</p>
						: (
							<ul className="entries">
								{state.sessions.map((row) => {
									const key = `session:${row.id}`;
									return (
										<li className="entry" key={row.id}>
											<div className="entry-head" data-one-line>
												<span className="entry-name">{row.nick || "Unnamed peer"}</span>
												<span className="tag" data-tone="quiet">{row.transport}</span>
												{
													/* The same eight characters, in the same clothes, as the
												    name rows above: it is what ties a registered nickname
												    to the connection holding it. */
												}
												{row.id.slice(0, 8)}
												{row.you && <span className="tag" data-tone="quiet">yours</span>}
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
															Disconnect…
														</Button>
													)}
												</div>
											</div>
											{acts.confirm(
												key,
												"Every capability occurrence owned by this connection is retired with it.",
												"Disconnect session",
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
						act="Disconnect"
						past="Disconnected"
						subject="peer sessions"
						effect="Every capability occurrence owned by those connections is retired with them."
						search={state.search}
						total={state.totals.sessions}
					/>
				</div>
			</section>
			<section className="ops-section" id="operatorRooms">
				<SectionTitle count={state.totals.rooms}>
					Rooms and object capabilities
				</SectionTitle>
				<div className="group well">
					<p className="hint">
						Each row is an application owner the directory can retire as one transaction. Local rooms
						release membership capabilities, peered rooms release their retained room reference, and IRC
						rooms part through the bridge that owns their sockets.
					</p>
					{state.rooms.length === 0
						? <p className="empty">No room owners are live.</p>
						: (
							<ul className="entries">
								{state.rooms.map((row) => {
									const key = `room:${row.id}`;
									const proof = ROOM_PROOF_FACE[row.proof];
									const action = row.kind === "peered"
										? "Remove peered publication"
										: row.kind === "pending-peered"
										? "Cancel pending publication"
										: row.kind === "irc"
										? "Part IRC bridge"
										: "Close room generation";
									const effect = row.kind === "peered"
										? "The directory releases its retained room capability and removes this exact publication. References already handed to members stay with those sessions."
										: row.kind === "pending-peered"
										? "The pending handoff is cancelled through its peering owner, its retained room reference is released, and its readiness promise is refused."
										: row.kind === "irc"
										? "The gateway retires every IRC seat, closes the bridge connection, and removes its room publication."
										: "Every membership and room-owned capability occurrence is released. The peer sessions and any separately issued durable link remain.";
									return (
										<li className="entry" key={row.id} data-kind={row.kind}>
											<div className="entry-head" data-one-line>
												<span className="entry-name">
													{row.name || "Unnamed private room"}
												</span>
												<span className="tag" data-tone="quiet">
													{ROOM_KIND_LABEL[row.kind] ?? row.kind}
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
												<p className="entry-meta">
													from {row.origin}
												</p>
											)}
											{row.retainedCapabilities !== null && (
												<p className="entry-meta">
													retains {row.retainedCapabilities}{" "}
													capability occurrence{row.retainedCapabilities === 1 ? "" : "s"}
												</p>
											)}
											{row.members.length > 0 && (
												<p className="entry-meta">
													with {row.members.map((member) =>
														member.state === ""
															? member.nick
															: `${member.nick} (${member.state})`
													).join(", ")}
												</p>
											)}
											{acts.confirm(key, effect, action, () =>
												session.removeOperatorRoom(row.id))}
											{acts.why[key] != null && <Said kind="failure">{acts.why[key]}</Said>}
										</li>
									);
								})}
							</ul>
						)}
					{more("rooms")}
					<OperatorSweep
						category="rooms"
						act="Remove"
						past="Removed"
						subject="room owners"
						effect="Each owner is retired as one transaction: memberships and room-owned capability occurrences are released."
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
				// Through the pane's own acts, which is what every other press here
				// goes through: it marks the filter busy and keeps the refusal. The
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
					Room moderator authority
				</SectionTitle>
				<div className="group well" id="roomModerationCapabilities">
					<p className="hint">
						Grant a room moderator capability for recovery or handoff. Rotating it stops copied and
						already-live old holders. Active IRC bridges appear through their own source authority, and
						peered rooms remain with their remote source.
					</p>
					{state.stewardships.length === 0
						? <p className="empty">This server owns no rooms right now.</p>
						: (
							<ul className="entries">
								{state.stewardships.map((row) => {
									const title = row.label || "Private room";
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
																Rotate…
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
																	? "Granting…"
																	: "Grant moderator capability"}
															</Button>
														)}
												</div>
											</div>
											{row.stewardLink !== null && (
												<CopyField
													compact
													text={row.stewardLink}
													label={`Copy ${title}'s room moderator capability`}
												/>
											)}
											{acts.confirm(
												key,
												"Every old copy stops moderating this room immediately, including references already in use.",
												"Revoke old moderator capability",
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
					Directory trouble
				</SectionTitle>
				<div className="group well">
					<p className="hint">
						The same bounded process journal diagnostics reports. Clearing acknowledges these rows. It
						changes no room, session, or retained history.
					</p>
					{state.trouble.length === 0 ? <p className="empty">The directory has reported no trouble.</p> : (
						<>
							<ul className="ops-trouble">
								{state.trouble.map((row, at) => (
									<li key={`${row.source}:${row.reason}:${at}`}>
										<span className="ops-kind">{row.source}</span>
										<span className="entry-meta">{row.reason}</span>
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
									Clear journal…
								</Button>
							</div>
							{acts.confirm(
								"trouble:all",
								"Every current diagnostic row is acknowledged and removed. New failures will still be recorded.",
								"Clear trouble journal",
								() => session.clearOperatorTrouble(),
							)}
							{acts.why["trouble:all"] != null && <Said kind="failure">{acts.why["trouble:all"]}</Said>}
						</>
					)}
					{more("trouble")}
				</div>
			</section>
			<section className="ops-section" id="operatorReset">
				<SectionTitle>Reset and recovery</SectionTitle>
				<div className="group well">
					<p className="hint">
						Reset one authority class at a time. This operator connection remains so the action can answer.
					</p>
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
