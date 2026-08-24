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
import { usePeer } from "../peer.ts";
import { useStore } from "../hooks.ts";
import type { IrcGatewayState } from "../types.ts";
import { Button } from "../Button.tsx";
import { Switch } from "../Switch.tsx";
import { Said } from "../Said.tsx";
import { OpsHead } from "./Head.tsx";

export function IrcPane({ state }: { state: IrcGatewayState | null }) {
	const peer = usePeer();
	const home = useStore().homeDir;
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
	const [why, setWhy] = useState<string | null>(null);

	// The page draws one pane per held capability; see the listeners pane.
	if (state === null) return null;

	const bridge = () => {
		setWhy(null);
		setJoining(true);
		void peer.joinIrc({
			network: network.trim(),
			channel: channel.trim(),
			host: host.trim(),
			port: port.trim() === "" ? (tls ? 6697 : 6667) : Number(port.trim()),
			tls,
			nick: nick.trim(),
			sasl: saslAccount.trim() === "" ? undefined : { account: saslAccount.trim(), password: saslPassword },
		}).then((refused) => {
			setJoining(false);
			if (refused !== "") {
				setWhy(refused);
				return;
			}
			setNetwork("");
			setChannel("");
			setSaslPassword("");
		});
	};

	const field = (
		id: string,
		name: string,
		value: string,
		onValue: (next: string) => void,
		placeholder: string,
	) => (
		<div className="ops-opt">
			<span className="ops-opt-name">{name}</span>
			<input
				id={id}
				className="field"
				value={value}
				placeholder={placeholder}
				onChange={(event) => onValue(event.currentTarget.value)}
			/>
		</div>
	);

	return (
		<div className="ops-pane">
			<OpsHead refresh={() => peer.refreshOpsCap("irc")}>
				IRC channels bridged into this directory as rooms, and the form that bridges another. Members are IRC
				citizens: each appears on the channel under their own nick and their lines go to IRC as them.
			</OpsHead>
			<p className="well-title overline">Bridge a channel</p>
			<div className="group well" role="group" aria-labelledby="ircJoinLegend">
				<form
					onSubmit={(event) => {
						event.preventDefault();
						bridge();
					}}
				>
					{field("ircJoinNetwork", "network", network, setNetwork, "libera")}
					{field("ircJoinChannel", "channel", channel, setChannel, "#ocapn")}
					{field("ircJoinHost", "host", host, setHost, "irc.libera.chat")}
					{field("ircJoinPort", "port", port, setPort, tls ? "6697" : "6667")}
					{field("ircJoinNick", "bot nick", nick, setNick, "pancake-rooms")}
					{field(
						"ircJoinSaslAccount",
						"bot account",
						saslAccount,
						setSaslAccount,
						"registered account (optional)",
					)}
					<div className="ops-opt">
						<span className="ops-opt-name">password</span>
						<input
							id="ircJoinSaslPassword"
							className="field"
							type="password"
							value={saslPassword}
							placeholder="its password; sent once, never kept"
							onChange={(event) => setSaslPassword(event.currentTarget.value)}
						/>
					</div>
					<p className="hint">
						The bot is the bridge's own connection: it carries the channel into the room under this nick,
						while each member speaks on IRC under their own. Networks that require a registered account take
						the bot's at connect time (SASL) and need TLS; the password goes to your rooms server once and
						is not remembered here.
					</p>
					<div className="switch-row">
						<p className="group-label" id="ircJoinTlsLegend">TLS</p>
						<Switch
							id="ircJoinTls"
							checked={tls}
							label="TLS"
							aria-labelledby="ircJoinTlsLegend"
							onClick={() => setTls(!tls)}
						/>
					</div>
					<Button id="ircJoinBtn" type="submit" disabled={joining}>
						{joining ? "Bridging…" : "Bridge the channel"}
					</Button>
					{why !== null && <Said id="ircJoinWhy" kind="failure">{why}</Said>}
				</form>
			</div>
			<p className="well-title overline">Bridged channels</p>
			<div className="group well" id="ircBridgedList">
				{state.bridged.length === 0
					? <p className="ops-empty">Nothing is bridged right now.</p>
					: (
						<ul className="ops-listeners">
							{state.bridged.map((row) => (
								<li className="ops-listener" key={row.roomName} data-room={row.roomName}>
									<div className="ops-listener-head">
										<span className="ops-listener-name">{row.roomName}</span>
										{row.status === "up"
											? <span className="ops-serving">connected</span>
											: <span className="ops-note">{row.status}</span>}
										{home !== null && (
											<Button
												variant="quiet"
												onClick={() => {
													peer.pickRoom(home, row.roomName);
													navigate("/");
												}}
											>
												Open
											</Button>
										)}
										<Button
											variant="quiet"
											onClick={() =>
												void peer.partIrc(row.network, row.channel)}
										>
											Part
										</Button>
									</div>
									<p className="hint">
										<code>{row.endpoint}</code>
									</p>
								</li>
							))}
						</ul>
					)}
			</div>
		</div>
	);
}
