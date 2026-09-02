// A bridge gateway and the connections and leases beneath it.
//
// The bridge describes its gateway — the words, the connection form, the lease
// form, and the connections it holds with their leases — and this draws it.
// Nothing here knows IRC; it knows a gateway. IRC is the one bridge that fills
// it today, so the words below read as IRC's.

import { Fragment, useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { Said } from "../Said.tsx";
import { BridgeFormView } from "../BridgeFormView.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { useRoomsState } from "../hooks.ts";
import { roomAddress } from "../route_address.ts";
import type { BridgeForm } from "../../../lib/bridge/form.ts";
import type { BridgeGateway, GatewayConnection, GatewayLease, GatewayStatus } from "../../../lib/bridge/gateway.ts";
import { OpsHead } from "./Head.tsx";
import { SectionTitle } from "./Section.tsx";

/** Map a bridge's link tone onto the status styles the pane already ships. */
function toneClass(status: GatewayStatus): string {
	switch (status.tone) {
		case "ok":
			return "status-up";
		case "pending":
			return "status-connecting";
		case "failed":
			return "status-backoff";
		default:
			return "status-dormant";
	}
}

function capitalize(word: string): string {
	return word.length === 0 ? word : word[0].toUpperCase() + word.slice(1);
}

/** Send only the form's primary action to the gateway. The wire knows two
 * verbs — open a connection, add a lease — and both belong to the primary; a
 * bridge declaring another action gets a refusal naming the boundary rather
 * than a wrong verb dispatched with empty answers. */
function primaryOnly(form: BridgeForm, action: string, send: () => Promise<string>): Promise<string> {
	const primary = form.actions.find((candidate) => candidate.tone === "primary");
	if (primary == null || action !== primary.id) {
		return Promise.resolve("Only this form's primary act is wired to the gateway yet.");
	}
	return send();
}

export function GatewayPane({ state }: { state: BridgeGateway | null }) {
	const session = useRoomsSession();
	const home = useRoomsState((current) => current.homeDir);
	const navigate = useNavigate();
	const [confirmingRemove, setConfirmingRemove] = useState<string | null>(null);
	const [confirmingClose, setConfirmingClose] = useState<string | null>(null);
	const [removing, setRemoving] = useState<ReadonlySet<string>>(() => new Set());
	const [closing, setClosing] = useState<ReadonlySet<string>>(() => new Set());
	const [removeWhy, setRemoveWhy] = useState<Readonly<Record<string, string | undefined>>>({});
	const [closeWhy, setCloseWhy] = useState<Readonly<Record<string, string | undefined>>>({});
	const watching = state?.connections.some((row) => row.status.tone === "pending") ?? false;

	useEffect(() => {
		if (!watching) return;
		let stopped = false;
		let timer: ReturnType<typeof setTimeout> | null = null;
		const refresh = async () => {
			await session.refreshOpsCap("irc");
			if (!stopped) timer = setTimeout(refresh, 3_000);
		};
		timer = setTimeout(refresh, 750);
		return () => {
			stopped = true;
			if (timer !== null) clearTimeout(timer);
		};
	}, [session, watching]);

	if (state === null) return null;

	const removeLease = (connection: GatewayConnection, lease: GatewayLease) => {
		const key = `${connection.id}\n${lease.id}`;
		setRemoving((prior) => new Set(prior).add(key));
		setRemoveWhy((prior) => ({ ...prior, [key]: undefined }));
		void session.removeBridgeLease(connection.id, lease.id).then((why) => {
			if (why !== "") setRemoveWhy((prior) => ({ ...prior, [key]: why }));
			else setConfirmingRemove(null);
		}).finally(() => {
			setRemoving((prior) => {
				const next = new Set(prior);
				next.delete(key);
				return next;
			});
		});
	};

	const close = (connection: GatewayConnection) => {
		setClosing((prior) => new Set(prior).add(connection.id));
		setCloseWhy((prior) => ({ ...prior, [connection.id]: undefined }));
		void session.closeBridgeConnection(connection.id).then((why) => {
			if (why !== "") setCloseWhy((prior) => ({ ...prior, [connection.id]: why }));
			else setConfirmingClose(null);
		}).finally(() => {
			setClosing((prior) => {
				const next = new Set(prior);
				next.delete(connection.id);
				return next;
			});
		});
	};

	const openRoom = (lease: GatewayLease) => {
		if (home === null || lease.roomName === null) return;
		session.pickRoom(home, lease.roomName);
		navigate(roomAddress(lease.roomName));
	};

	return (
		<div className="ops-pane irc-operations">
			<OpsHead refresh={() => session.refreshOpsCap("irc")}>{state.description}</OpsHead>

			<section className="ops-section" aria-labelledby="gatewayConnectionsTitle">
				<SectionTitle id="gatewayConnectionsTitle" count={state.connections.length}>
					{capitalize(state.connectionNounPlural)}
				</SectionTitle>
				{state.connections.length === 0
					? (
						<div className="irc-connections-empty well">
							<p>No {state.connectionNounPlural} yet.</p>
							<p className="hint">Open one below. A {state.leaseNoun} is not required.</p>
						</div>
					)
					: (
						<ul className="irc-connections">
							{state.connections.map((connection) => {
								const closingNow = closing.has(connection.id);
								return (
									<li
										className="irc-connection"
										key={connection.id}
										data-network={connection.title}
									>
										<header className="irc-connection-head">
											<div>
												<h4>{connection.title}</h4>
												<p className="irc-connection-meta">
													{connection.facts.map((fact, index) => (
														<Fragment key={fact.label}>
															{index > 0 && (
																<span
																	className="irc-connection-meta-sep"
																	aria-hidden="true"
																>
																	·
																</span>
															)}
															<span>{fact.value}</span>
														</Fragment>
													))}
												</p>
											</div>
											<span className={`irc-connection-status ${toneClass(connection.status)}`}>
												{connection.status.label}
											</span>
										</header>
										{connection.problem !== "" && <Said kind="failure">{connection.problem}</Said>}

										<div className="irc-channels">
											<div className="irc-channels-head">
												<h5>{capitalize(state.leaseNounPlural)}</h5>
												<span>{connection.leases.length}</span>
											</div>
											{connection.leases.length === 0
												? (
													<p className="irc-no-channels">
														No {state.leaseNounPlural}. This {state.connectionNoun}{" "}
														is retained without a live transport.
													</p>
												)
												: (
													<ul className="irc-channel-list">
														{connection.leases.map((lease) => {
															const rowKey = `${connection.id}\n${lease.id}`;
															const rowProblem = removeWhy[rowKey] ??
																(lease.problem === "" ? undefined : lease.problem);
															return (
																<li key={rowKey}>
																	<div className="irc-channel-name">
																		<strong>{lease.title}</strong>
																		<span>{lease.status.label}</span>
																	</div>
																	{confirmingRemove === rowKey
																		? (
																			<Confirm
																				label={`${state.leaseRemoval.label} ${lease.title}`}
																				say={`${state.leaseRemoval.label} ${lease.title} from ${connection.title}? ${state.leaseRemoval.say}`}
																				keep={state.leaseRemoval.keep}
																				commit={state.leaseRemoval.commit}
																				busy={removing.has(rowKey)}
																				onKeep={() => setConfirmingRemove(null)}
																				onCommit={() =>
																					removeLease(connection, lease)}
																			/>
																		)
																		: (
																			<div className="actions">
																				{home !== null &&
																					lease.roomName !== null && (
																					<Button
																						variant="quiet"
																						onClick={() => openRoom(lease)}
																					>
																						Open room
																					</Button>
																				)}
																				<Button
																					variant="quiet"
																					disabled={closingNow}
																					onClick={() =>
																						setConfirmingRemove(rowKey)}
																				>
																					{`${state.leaseRemoval.label}…`}
																				</Button>
																			</div>
																		)}
																	{rowProblem !== undefined && (
																		<Said kind="failure">{rowProblem}</Said>
																	)}
																</li>
															);
														})}
													</ul>
												)}
											<div className="irc-channel-add">
												<label id={`gatewayLease-${connection.id}-label`}>
													Add {state.leaseNoun}
												</label>
												<BridgeFormView
													form={state.leaseForm}
													idPrefix={`gatewayLease-${connection.id}`}
													connected={!closingNow}
													resetOnDone
													layout="row"
													onAct={(action, answers, secrets) =>
														primaryOnly(state.leaseForm, action, () =>
															session.addBridgeLease(connection.id, {
																...answers,
																...secrets,
															}))}
												/>
											</div>
										</div>

										{confirmingClose === connection.id
											? (
												<Confirm
													label={`Close ${connection.title}`}
													say={connection.leases.length === 0
														? `Delete the saved ${connection.title} ${state.connectionNoun}?`
														: `Delete this ${state.connectionNoun} and its ${connection.leases.length} bridged ${
															connection.leases.length === 1
																? state.leaseNoun
																: state.leaseNounPlural
														}?`}
													keep={`Keep ${state.connectionNoun}`}
													commit={`Close ${state.connectionNoun}`}
													busy={closingNow}
													onKeep={() => setConfirmingClose(null)}
													onCommit={() => close(connection)}
												/>
											)
											: (
												<div className="irc-connection-actions">
													<Button
														variant="quiet"
														onClick={() => setConfirmingClose(connection.id)}
													>
														Close {state.connectionNoun}…
													</Button>
												</div>
											)}
										{closeWhy[connection.id] !== undefined && (
											<Said kind="failure">{closeWhy[connection.id]}</Said>
										)}
									</li>
								);
							})}
						</ul>
					)}
			</section>

			<section className="ops-section irc-new" aria-labelledby="gatewayNewTitle">
				<SectionTitle id="gatewayNewTitle">{state.connectionForm.title}</SectionTitle>
				<div className="well">
					<BridgeFormView
						form={state.connectionForm}
						idPrefix="gatewayConnection"
						connected
						resetOnDone
						layout="grid"
						onAct={(action, answers, secrets) =>
							primaryOnly(state.connectionForm, action, () =>
								session.openBridgeConnection({ ...answers, ...secrets }))}
					/>
				</div>
			</section>
		</div>
	);
}
