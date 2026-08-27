// The IRC pane of the Operations page, drawn only while this tab holds the
// gateway capability (the Capabilities toggle is how it is taken).
//
// One well bridges a new channel: the channel's own coordinates as labeled
// fields, TLS on unless the operator says otherwise, and a refusal landing
// beside the form that asked. Under it, one row per bridged channel with the
// room it stands under, where its connection points, and the part that takes
// it down. Members are IRC citizens through per-reader connections; the pane
// says so where an operator would otherwise assume a shared relay nick.

import { useState } from "react";
import { useNavigate } from "react-router";
import { useRoomsSession } from "../controller/session.ts";
import { useRoomsState } from "../hooks.ts";
import type { IrcGatewayState } from "../types.ts";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { Switch } from "../Switch.tsx";
import { Said } from "../Said.tsx";
import { identifierField } from "../field.ts";
import { OpsHead } from "./Head.tsx";

export function IrcPane({ state }: { state: IrcGatewayState | null }) {
	const session = useRoomsSession();
	const home = useRoomsState((state) => state.homeDir);
	const navigate = useNavigate();
	const [network, setNetwork] = useState("");
	const [channel, setChannel] = useState("");
	const [host, setHost] = useState("");
	const [port, setPort] = useState("");
	const [nick, setNick] = useState("");
	const [saslAccount, setSaslAccount] = useState("");
	const [saslPassword, setSaslPassword] = useState("");
	const [tls, setTls] = useState(true);
	const [joining, setJoining] = useState(false);
	const [bridged, setBridged] = useState("");
	const [why, setWhy] = useState<string | null>(null);
	const [parting, setParting] = useState<ReadonlySet<string>>(() => new Set());
	const [partWhy, setPartWhy] = useState<Partial<Record<string, string>>>({});

	// The page draws one pane per held capability; see the listeners pane.
	if (state === null) return null;
	const portNumber = port === "" ? (tls ? 6697 : 6667) : Number(port);
	const canBridge = network !== "" && channel !== "" && host !== "" && nick !== "" &&
		Number.isInteger(portNumber) && portNumber >= 1 && portNumber <= 65535;

	const bridge = () => {
		setWhy(null);
		setBridged("");
		setJoining(true);
		void session.joinIrc({
			network,
			channel,
			host,
			port: portNumber,
			tls,
			nick,
			sasl: saslAccount === "" ? undefined : { account: saslAccount, password: saslPassword },
		}).then((refused) => {
			setJoining(false);
			if (refused !== "") {
				setWhy(refused);
				return;
			}
			setBridged(`${network}/${channel} is bridged; its room is listed below.`);
			setNetwork("");
			setChannel("");
			setSaslPassword("");
		});
	};

	const part = (network: string, channel: string) => {
		const key = `${network}\n${channel}`;
		setParting((prior) => new Set(prior).add(key));
		setPartWhy((prior) => ({ ...prior, [key]: undefined }));
		void session.partIrc(network, channel).then((refused) => {
			setParting((prior) => {
				const next = new Set(prior);
				next.delete(key);
				return next;
			});
			if (refused !== "") setPartWhy((prior) => ({ ...prior, [key]: refused }));
		});
	};

	const field = (
		id: string,
		name: string,
		value: string,
		onValue: (next: string) => void,
		placeholder: string,
	) => (
		<Field id={id} label={name} layout="inline" width={id === "ircJoinPort" ? "short" : undefined}>
			{(wiring) => (
				<input
					id={wiring.id}
					className="field"
					type={id === "ircJoinPort" ? "number" : "text"}
					inputMode={id === "ircJoinPort" ? "numeric" : undefined}
					min={id === "ircJoinPort" ? 1 : undefined}
					max={id === "ircJoinPort" ? 65535 : undefined}
					value={value}
					placeholder={placeholder}
					disabled={joining}
					required={id !== "ircJoinPort" && id !== "ircJoinSaslAccount"}
					{...identifierField}
					onChange={(event) => onValue(event.currentTarget.value)}
				/>
			)}
		</Field>
	);

	return (
		<div className="ops-pane">
			<OpsHead refresh={() => session.refreshOpsCap("irc")}>
				IRC channels bridged into this directory as rooms, and the form that bridges another. Members are IRC
				citizens: each appears on the channel under their own nick and their lines go to IRC as them.
			</OpsHead>
			<h3 className="well-title overline" id="ircJoinLegend">Bridge a channel</h3>
			<form
				className="group well"
				role="group"
				aria-labelledby="ircJoinLegend"
				onSubmit={(event) => {
					event.preventDefault();
					bridge();
				}}
			>
				{field("ircJoinNetwork", "Network", network, setNetwork, "libera")}
				{field("ircJoinChannel", "Channel", channel, setChannel, "#ocapn")}
				{field("ircJoinHost", "Host", host, setHost, "irc.libera.chat")}
				{field("ircJoinPort", "Port", port, setPort, tls ? "6697" : "6667")}
				{field("ircJoinNick", "Bot nick", nick, setNick, "pancake-rooms")}
				{field(
					"ircJoinSaslAccount",
					"Bot account",
					saslAccount,
					setSaslAccount,
					"registered account (optional)",
				)}
				<Field id="ircJoinSaslPassword" label="Password" layout="inline">
					{(wiring) => (
						<input
							id={wiring.id}
							className="field"
							type="password"
							value={saslPassword}
							placeholder="sent once and never kept"
							disabled={joining}
							{...identifierField}
							onChange={(event) => setSaslPassword(event.currentTarget.value)}
						/>
					)}
				</Field>
				<p className="hint">
					The bot is the bridge's own connection: it carries the channel into the room under this nick, while
					each member speaks on IRC under their own. Networks that require a registered account take the bot's
					at connect time (SASL) and need TLS. The password goes to your rooms server once and is not
					remembered here.
				</p>
				<div className="switch-row">
					<p className="group-label" id="ircJoinTlsLegend">TLS</p>
					<Switch
						id="ircJoinTls"
						checked={tls}
						label="TLS"
						aria-labelledby="ircJoinTlsLegend"
						disabled={joining}
						onClick={() => setTls(!tls)}
					/>
				</div>
				<div className="actions">
					<Button id="ircJoinBtn" type="submit" busy={joining} disabled={!canBridge}>
						{joining ? "Bridging…" : "Bridge the channel"}
					</Button>
				</div>
				{bridged !== "" && <Said kind="success">{bridged}</Said>}
				{why !== null && <Said id="ircJoinWhy" kind="failure">{why}</Said>}
			</form>
			<h3 className="well-title overline" id="ircBridgedLegend">Bridged channels</h3>
			<div className="group well" id="ircBridgedList" role="group" aria-labelledby="ircBridgedLegend">
				{state.bridged.length === 0
					? <p className="empty">Nothing is bridged right now.</p>
					: (
						<ul className="entries">
							{state.bridged.map((row) => {
								const key = `${row.network}\n${row.channel}`;
								const waiting = parting.has(key);
								return (
									<li className="entry" key={row.roomName} data-room={row.roomName}>
										<div className="entry-head">
											<span className="entry-name">{row.roomName}</span>
											{row.status === "up"
												? <span className="ops-serving">connected</span>
												: <span className="entry-meta">{row.status}</span>}
											<div className="actions">
												{home !== null && (
													<Button
														variant="quiet"
														onClick={() => {
															session.pickRoom(home, row.roomName);
															navigate("/");
														}}
													>
														Open
													</Button>
												)}
												<Button
													variant="quiet"
													busy={waiting}
													onClick={() => part(row.network, row.channel)}
												>
													{waiting ? "Parting…" : "Part"}
												</Button>
											</div>
										</div>
										<p className="entry-meta">
											<code>{row.endpoint}</code>
										</p>
										{partWhy[key] !== undefined && <Said kind="failure">{partWhy[key]}</Said>}
									</li>
								);
							})}
						</ul>
					)}
			</div>
		</div>
	);
}
