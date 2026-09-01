// IRC network capabilities and the channel leases beneath them.
//
// The hierarchy is the product model: an operator retains a network without
// having to invent a first channel, then adds and removes bridged channels
// independently. A zero-channel network is still owned and manageable; its
// transport is dormant until a channel lease enacts it.

import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { Field } from "../Field.tsx";
import { Said } from "../Said.tsx";
import { Switch } from "../Switch.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { identifierField } from "../field.ts";
import { useRoomsState } from "../hooks.ts";
import { roomAddress } from "../route_address.ts";
import type { IrcBridgeRow, IrcGatewayState } from "../types.ts";
import { OpsHead } from "./Head.tsx";
import { SectionTitle } from "./Section.tsx";

const connectionKey = (network: string): string => network.toLowerCase();
const channelKey = (network: string, channel: string): string => `${connectionKey(network)}\n${channel.toLowerCase()}`;

function statusLabel(status: IrcGatewayState["networks"][number]["status"]): string {
	return status === "dormant" ? "ready" : status === "up" ? "connected" : status;
}

export function IrcPane({ state }: { state: IrcGatewayState | null }) {
	const session = useRoomsSession();
	const home = useRoomsState((current) => current.homeDir);
	const navigate = useNavigate();
	const [network, setNetwork] = useState("");
	const [host, setHost] = useState("");
	const [port, setPort] = useState("");
	const [nick, setNick] = useState("");
	const [saslAccount, setSaslAccount] = useState("");
	const [saslPassword, setSaslPassword] = useState("");
	const [tls, setTls] = useState(true);
	const [opening, setOpening] = useState(false);
	const [opened, setOpened] = useState("");
	const [openWhy, setOpenWhy] = useState<string | null>(null);
	const [channelDrafts, setChannelDrafts] = useState<Readonly<Record<string, string>>>({});
	const [joining, setJoining] = useState<ReadonlySet<string>>(() => new Set());
	const [parting, setParting] = useState<ReadonlySet<string>>(() => new Set());
	const [confirmingPart, setConfirmingPart] = useState<string | null>(null);
	const [channelWhy, setChannelWhy] = useState<Readonly<Record<string, string | undefined>>>({});
	const [confirmingClose, setConfirmingClose] = useState<string | null>(null);
	const [closing, setClosing] = useState<ReadonlySet<string>>(() => new Set());
	const [closeWhy, setCloseWhy] = useState<Readonly<Record<string, string | undefined>>>({});
	const watchingConnection = state?.networks.some((row) => row.status === "connecting" || row.status === "backoff") ??
		false;
	const channelsByNetwork = useMemo(() => {
		const grouped = new Map<string, IrcBridgeRow[]>();
		for (const row of state?.bridged ?? []) {
			const key = connectionKey(row.network);
			const channels = grouped.get(key);
			if (channels == null) grouped.set(key, [row]);
			else channels.push(row);
		}
		return grouped;
	}, [state?.bridged]);
	useEffect(() => {
		if (!watchingConnection) return;
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
	}, [session, watchingConnection]);

	if (state === null) return null;
	const portNumber = port === "" ? (tls ? 6697 : 6667) : Number(port);
	const canOpen = network !== "" && host !== "" && nick !== "" && Number.isInteger(portNumber) &&
		portNumber >= 1 && portNumber <= 65535 && (saslAccount === "" || saslPassword !== "");

	const open = () => {
		setOpening(true);
		setOpened("");
		setOpenWhy(null);
		void session.openIrcNetwork({
			network,
			host,
			port: portNumber,
			tls,
			nick,
			sasl: saslAccount === "" ? undefined : { account: saslAccount, password: saslPassword },
		}).then((why) => {
			if (why !== "") setOpenWhy(why);
			else {
				setOpened(`${network} is ready. Add a channel from its connection card.`);
				setNetwork("");
				setSaslPassword("");
			}
		}).finally(() => setOpening(false));
	};

	const join = (network: string) => {
		const networkId = connectionKey(network);
		const channelName = (channelDrafts[networkId] ?? "").trim().replace(/^#+/, "");
		if (channelName === "") return;
		const channel = `#${channelName}`;
		const key = channelKey(network, channel);
		setJoining((prior) => new Set(prior).add(networkId));
		setChannelWhy((prior) => ({ ...prior, [key]: undefined }));
		void session.joinIrcChannel(network, channel).then((why) => {
			if (why !== "") setChannelWhy((prior) => ({ ...prior, [key]: why }));
			else setChannelDrafts((prior) => ({ ...prior, [networkId]: "" }));
		}).finally(() => {
			setJoining((prior) => {
				const next = new Set(prior);
				next.delete(networkId);
				return next;
			});
		});
	};

	const part = (network: string, channel: string) => {
		const key = channelKey(network, channel);
		setParting((prior) => new Set(prior).add(key));
		setChannelWhy((prior) => ({ ...prior, [key]: undefined }));
		void session.partIrc(network, channel).then((why) => {
			if (why !== "") setChannelWhy((prior) => ({ ...prior, [key]: why }));
			else setConfirmingPart(null);
		}).finally(() => {
			setParting((prior) => {
				const next = new Set(prior);
				next.delete(key);
				return next;
			});
		});
	};

	const close = (network: string) => {
		const key = connectionKey(network);
		setClosing((prior) => new Set(prior).add(key));
		setCloseWhy((prior) => ({ ...prior, [key]: undefined }));
		void session.closeIrcNetwork(network).then((why) => {
			if (why !== "") setCloseWhy((prior) => ({ ...prior, [key]: why }));
			else setConfirmingClose(null);
		}).finally(() => {
			setClosing((prior) => {
				const next = new Set(prior);
				next.delete(key);
				return next;
			});
		});
	};

	const openRoom = (row: IrcBridgeRow) => {
		if (home === null) return;
		session.pickRoom(home, row.roomName);
		navigate(roomAddress(row.roomName));
	};

	return (
		<div className="ops-pane irc-operations">
			<OpsHead refresh={() => session.refreshOpsCap("irc")}>
				IRC networks this server may administer. Each connection owns an identity, and its channels become
				ordinary Rooms rooms. Members speak on IRC under their own network identity.
			</OpsHead>

			<section className="ops-section" aria-labelledby="ircConnectionsTitle">
				<SectionTitle id="ircConnectionsTitle" count={state.networks.length}>IRC connections</SectionTitle>
				{state.networks.length === 0
					? (
						<div className="irc-connections-empty well">
							<p>No IRC connections yet.</p>
							<p className="hint">Open one below. A channel is not required.</p>
						</div>
					)
					: (
						<ul className="irc-connections">
							{state.networks.map((connection) => {
								const key = connectionKey(connection.network);
								const channels = channelsByNetwork.get(key) ?? [];
								const draft = channelDrafts[key] ?? "";
								const closingNow = closing.has(key);
								return (
									<li className="irc-connection" key={key} data-network={connection.network}>
										<header className="irc-connection-head">
											<div>
												<h4>{connection.network}</h4>
												<p className="irc-connection-meta">
													{connection.endpoint}
													<span aria-hidden="true">·</span>{" "}
													{connection.tls ? "TLS" : "cleartext"}
													<span aria-hidden="true">·</span> <span>{connection.nick}</span>
													{connection.account !== "" && (
														<>
															<span aria-hidden="true">·</span> {connection.account}
														</>
													)}
												</p>
											</div>
											<span className={`irc-connection-status status-${connection.status}`}>
												{statusLabel(connection.status)}
											</span>
										</header>
										{connection.problem !== "" && <Said kind="failure">{connection.problem}</Said>}

										<div className="irc-channels">
											<div className="irc-channels-head">
												<h5>Channels</h5>
												<span>{channels.length}</span>
											</div>
											{channels.length === 0
												? (
													<p className="irc-no-channels">
														No channels. This connection is retained without a live
														transport.
													</p>
												)
												: (
													<ul className="irc-channel-list">
														{channels.map((row) => {
															const rowKey = channelKey(row.network, row.channel);
															const rowProblem = channelWhy[rowKey] ??
																(row.problem === "" ? undefined : row.problem);
															return (
																<li key={rowKey}>
																	<div className="irc-channel-name">
																		<strong>{row.channel}</strong>
																		<span>
																			{row.status === "up" ? "live" : row.status}
																		</span>
																	</div>
																	{confirmingPart === rowKey
																		? (
																			<Confirm
																				label={`Part ${row.channel}`}
																				say={`Part ${row.channel} from ${row.network}? Its bridged Rooms room will close and every current membership will end.`}
																				keep="Keep channel"
																				commit="Part channel"
																				busy={parting.has(rowKey)}
																				onKeep={() => setConfirmingPart(null)}
																				onCommit={() =>
																					part(row.network, row.channel)}
																			/>
																		)
																		: (
																			<div className="actions">
																				{home !== null && (
																					<Button
																						variant="quiet"
																						onClick={() => openRoom(row)}
																					>
																						Open room
																					</Button>
																				)}
																				<Button
																					variant="quiet"
																					disabled={closingNow}
																					onClick={() =>
																						setConfirmingPart(rowKey)}
																				>
																					Part…
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
											<form
												className="irc-channel-add"
												aria-label={`Add a channel to ${connection.network}`}
												onSubmit={(event) => {
													event.preventDefault();
													join(connection.network);
												}}
											>
												<label htmlFor={`ircChannel-${key}`}>Add channel</label>
												<div className="irc-channel-field">
													<span aria-hidden="true">#</span>
													<input
														id={`ircChannel-${key}`}
														className="field"
														value={draft}
														placeholder="pancake"
														disabled={joining.has(key) || closingNow}
														{...identifierField}
														onChange={(event) => {
															const value = event.currentTarget.value.replace(/^#+/, "");
															setChannelDrafts((prior) => ({ ...prior, [key]: value }));
														}}
													/>
												</div>
												<Button
													type="submit"
													busy={joining.has(key)}
													disabled={draft.trim().replace(/^#+/, "") === "" || closingNow}
												>
													{joining.has(key) ? "Joining…" : "Join"}
												</Button>
											</form>
										</div>

										{confirmingClose === key
											? (
												<Confirm
													label={`Close ${connection.network}`}
													say={channels.length === 0
														? `Delete the saved ${connection.network} connection?`
														: `Delete this connection and part its ${channels.length} bridged ${
															channels.length === 1 ? "channel" : "channels"
														}?`}
													keep="Keep connection"
													commit="Close connection"
													busy={closingNow}
													onKeep={() => setConfirmingClose(null)}
													onCommit={() => close(connection.network)}
												/>
											)
											: (
												<div className="irc-connection-actions">
													<Button variant="quiet" onClick={() => setConfirmingClose(key)}>
														Close connection…
													</Button>
												</div>
											)}
										{closeWhy[key] !== undefined && <Said kind="failure">{closeWhy[key]}</Said>}
									</li>
								);
							})}
						</ul>
					)}
			</section>

			<section className="ops-section irc-new" aria-labelledby="ircNewTitle">
				<SectionTitle id="ircNewTitle">New IRC connection</SectionTitle>
				<form
					className="well irc-new-form"
					onSubmit={(event) => {
						event.preventDefault();
						open();
					}}
				>
					<div className="irc-new-grid">
						<ConnectionField
							id="ircNetwork"
							label="Name"
							value={network}
							placeholder="Libera"
							disabled={opening}
							onValue={setNetwork}
						/>
						<ConnectionField
							id="ircHost"
							label="Server"
							value={host}
							placeholder="irc.libera.chat"
							disabled={opening}
							onValue={setHost}
						/>
						<ConnectionField
							id="ircPort"
							label="Port"
							value={port}
							placeholder={tls ? "6697" : "6667"}
							disabled={opening}
							onValue={setPort}
							port
						/>
						<ConnectionField
							id="ircNick"
							label="Feed nick"
							value={nick}
							placeholder="pancake-rooms"
							disabled={opening}
							onValue={setNick}
						/>
						<ConnectionField
							id="ircAccount"
							label="Account"
							value={saslAccount}
							placeholder="optional"
							disabled={opening}
							onValue={setSaslAccount}
							optional
						/>
						<ConnectionField
							id="ircPassword"
							label="Password"
							value={saslPassword}
							placeholder="sent to your server"
							disabled={opening}
							onValue={setSaslPassword}
							password
							optional
						/>
					</div>
					<div className="irc-new-foot">
						<div className="switch-row irc-tls-row">
							<p className="group-label" id="ircTlsLabel">TLS</p>
							<Switch
								id="ircTls"
								checked={tls}
								label="TLS"
								aria-labelledby="ircTlsLabel"
								disabled={opening}
								onClick={() => setTls(!tls)}
							/>
						</div>
						<p className="hint">
							This creates the network capability only. Add channels after it appears above.
						</p>
						<Button id="ircOpenNetwork" type="submit" busy={opening} disabled={!canOpen}>
							{opening ? "Opening…" : "Open connection"}
						</Button>
					</div>
					{opened !== "" && <Said kind="success">{opened}</Said>}
					{openWhy !== null && <Said kind="failure">{openWhy}</Said>}
				</form>
			</section>
		</div>
	);
}

function ConnectionField(
	{ id, label, value, placeholder, disabled, onValue, port = false, password = false, optional = false }: {
		id: string;
		label: string;
		value: string;
		placeholder: string;
		disabled: boolean;
		onValue: (next: string) => void;
		port?: boolean;
		password?: boolean;
		optional?: boolean;
	},
) {
	return (
		<Field id={id} label={label}>
			{(wiring) => (
				<input
					id={wiring.id}
					className="field"
					type={password ? "password" : port ? "number" : "text"}
					inputMode={port ? "numeric" : undefined}
					min={port ? 1 : undefined}
					max={port ? 65535 : undefined}
					value={value}
					placeholder={placeholder}
					disabled={disabled}
					required={!optional && !port}
					{...identifierField}
					onChange={(event) => onValue(event.currentTarget.value)}
				/>
			)}
		</Field>
	);
}
