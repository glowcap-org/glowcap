// The IRC gateway, described as an ordinary bridge gateway.
//
// This is where IRC says what its operator gateway asks for and looks like,
// the way `ircIdentityForm` says what its identity asks for. The connection
// form is IRC's network fields, the lease form is one channel, and the words
// are IRC's; Rooms draws all of it without knowing any of it. The answer
// parsers read a submission back against the form this file declared, so the
// field ids are the one contract between the two halves.

import type { BridgeForm } from "../../lib/bridge/form.ts";
import { readBridgeAnswers } from "../../lib/bridge/form.ts";
import {
	type BridgeGateway,
	encodeBridgeGateway,
	type GatewayStatus,
	MAX_GATEWAY_NAME,
} from "../../lib/bridge/gateway.ts";
import { MAX_FORM_SAID, MAX_FORM_VALUE } from "../../lib/limits.ts";
import type { OperatorIrcNetworks } from "./networks.ts";
import type { IrcNetworkChoice } from "./model.ts";

/** One retained bridge as the projection reads it: which network holds it, the
 * channel and the room it became, its correlation id, and its live status. */
export interface IrcBridgeSnapshotSource {
	readonly network: { readonly choice: { readonly network: string; readonly host: string; readonly port: number } };
	readonly channel: string;
	readonly roomName: string;
	readonly entryId: string;
	readonly status: "connecting" | "up" | "backoff";
	readonly problem: string;
}

/** The field ids the IRC gateway forms declare. They are the one contract
 * between the form this file draws and the answers it reads back, so a caller
 * that fills a submission by hand (a test standing in for the reader) shares
 * them from here rather than restating the strings. */
export const IRC_GATEWAY_FIELDS = {
	name: "name",
	host: "host",
	port: "port",
	nick: "nick",
	tls: "tls",
	account: "account",
	password: "password",
	channel: "channel",
} as const;

const NAME = IRC_GATEWAY_FIELDS.name;
const HOST = IRC_GATEWAY_FIELDS.host;
const PORT = IRC_GATEWAY_FIELDS.port;
const NICK = IRC_GATEWAY_FIELDS.nick;
const TLS = IRC_GATEWAY_FIELDS.tls;
const ACCOUNT = IRC_GATEWAY_FIELDS.account;
const PASSWORD = IRC_GATEWAY_FIELDS.password;
const CHANNEL = IRC_GATEWAY_FIELDS.channel;

const OPEN_ACTION = "open";
const ADD_ACTION = "add";

/** The form IRC asks Rooms to draw for a new network connection. */
function ircConnectionForm(): BridgeForm {
	return {
		scope: "connection",
		title: "New IRC connection",
		said: "This creates the network capability only. Add channels after it appears.",
		fields: [
			{ kind: "text", id: NAME, label: "Name", placeholder: "Libera", value: "", required: true },
			{ kind: "text", id: HOST, label: "Server", placeholder: "irc.libera.chat", required: true },
			{
				kind: "text",
				id: PORT,
				label: "Port",
				placeholder: "6697",
				hint: "6697 with TLS, 6667 without",
				required: false,
			},
			{ kind: "text", id: NICK, label: "Feed nick", placeholder: "glowcap-rooms", required: true },
			{ kind: "text", id: ACCOUNT, label: "Account", placeholder: "optional", required: false },
			{ kind: "secret", id: PASSWORD, label: "Password", placeholder: "sent to your server", required: false },
			{ kind: "toggle", id: TLS, label: "TLS", on: true, reveals: [] },
		],
		actions: [
			{ id: OPEN_ACTION, label: "Open connection", busyLabel: "Opening…", tone: "primary", remembered: false },
		],
	};
}

/** The form IRC asks Rooms to draw for a new channel under a connection. */
function ircLeaseForm(): BridgeForm {
	return {
		scope: "lease",
		title: "Add channel",
		said: "",
		fields: [{ kind: "text", id: CHANNEL, label: "Channel", prefix: "#", placeholder: "nowhere", required: true }],
		actions: [{ id: ADD_ACTION, label: "Join", busyLabel: "Joining…", tone: "primary", remembered: false }],
	};
}

/** A diagnostic or stated fact is shown, never owned back: the description
 * schema bounds what a snapshot may carry, so a longer text is cut to fit
 * rather than allowed to make the whole snapshot unparseable exactly when an
 * operator needs to read it. User-authored names take the refusal path above
 * instead; this is only for text the bridge itself produced or relayed. */
function shown(text: string, max: number): string {
	if (text.length <= max) return text;
	// Never cut through a surrogate pair: a relayed message may carry emoji.
	const cut = max - 1;
	const whole = text.charCodeAt(cut - 1) >= 0xd800 && text.charCodeAt(cut - 1) <= 0xdbff ? cut - 1 : cut;
	return `${text.slice(0, whole)}…`;
}

function networkStatus(status: string): GatewayStatus {
	switch (status) {
		case "up":
			return { label: "connected", tone: "ok" };
		case "connecting":
			return { label: "connecting", tone: "pending" };
		case "backoff":
			return { label: "reconnecting", tone: "pending" };
		default:
			return { label: "ready", tone: "idle" };
	}
}

function channelStatus(status: string): GatewayStatus {
	switch (status) {
		case "up":
			return { label: "live", tone: "ok" };
		case "backoff":
			return { label: "reconnecting", tone: "pending" };
		default:
			return { label: "connecting", tone: "pending" };
	}
}

interface NetworkView {
	readonly network: string;
	readonly status: string;
	readonly endpoint: string;
	readonly nick: string;
	readonly account: string;
	readonly tls: boolean;
	readonly problem: string;
}

function networkViews(networks: OperatorIrcNetworks): NetworkView[] {
	return networks.snapshot().map((row) => {
		const [network, status, endpoint, nick, account, tls, problem] = row as [
			string,
			string,
			string,
			string,
			string,
			boolean,
			string,
		];
		return { network, status, endpoint, nick, account, tls, problem };
	});
}

/** Describe the whole IRC gateway as a bridge gateway: its two forms, its
 * words, and its connections with their channel leases. */
export function projectBridgeGateway(
	networks: OperatorIrcNetworks,
	bridges: Iterable<IrcBridgeSnapshotSource>,
): string {
	const leasesByNetwork = new Map<string, IrcBridgeSnapshotSource[]>();
	for (const held of bridges) {
		const key = held.network.choice.network.toLowerCase();
		const list = leasesByNetwork.get(key);
		if (list == null) leasesByNetwork.set(key, [held]);
		else list.push(held);
	}
	const gateway: BridgeGateway = {
		title: "IRC bridges",
		description:
			"IRC networks this server may administer. Each connection owns an identity, and its channels become ordinary Rooms rooms. Members speak on IRC under their own network identity.",
		connectionNoun: "connection",
		connectionNounPlural: "connections",
		leaseNoun: "channel",
		leaseNounPlural: "channels",
		leaseRemoval: {
			label: "Part",
			say: "Parting closes its bridged Rooms room and ends every current membership.",
			keep: "Keep channel",
			commit: "Part channel",
		},
		connectionForm: ircConnectionForm(),
		leaseForm: ircLeaseForm(),
		connections: networkViews(networks).map((view) => {
			const facts = [
				{ label: "Endpoint", value: shown(view.endpoint, MAX_FORM_VALUE) },
				{ label: "Security", value: view.tls ? "TLS" : "cleartext" },
				{ label: "Nick", value: shown(view.nick, MAX_FORM_VALUE) },
				...(view.account === "" ? [] : [{ label: "Account", value: shown(view.account, MAX_FORM_VALUE) }]),
			];
			return {
				id: view.network,
				title: view.network,
				facts,
				status: networkStatus(view.status),
				problem: shown(view.problem, MAX_FORM_SAID),
				leases: (leasesByNetwork.get(view.network.toLowerCase()) ?? []).map((held) => ({
					id: held.channel,
					title: held.channel,
					status: channelStatus(held.status),
					problem: shown(held.problem, MAX_FORM_SAID),
					roomName: held.roomName === "" ? null : held.roomName,
					publicationId: held.entryId,
				})),
			};
		}),
	};
	return encodeBridgeGateway(gateway);
}

/** Read a connection-open submission back against the form above into IRC's
 * own network choice. `network` names which connection, so the server can also
 * demand it match a known name. */
export function connectionChoiceFromAnswers(raw: string): IrcNetworkChoice {
	const answers = readBridgeAnswers(raw);
	const name = (answers[NAME] ?? "").trim();
	const host = (answers[HOST] ?? "").trim();
	const nick = (answers[NICK] ?? "").trim();
	if (name === "" || host === "" || nick === "") {
		throw new Error("a connection needs a name, a server, and a nick");
	}
	if (name.length > MAX_GATEWAY_NAME) {
		throw new Error(`a connection name stays within ${MAX_GATEWAY_NAME} characters`);
	}
	const tls = answers[TLS] === "on";
	const portText = (answers[PORT] ?? "").trim();
	const port = portText === "" ? (tls ? 6697 : 6667) : Number(portText);
	if (!Number.isSafeInteger(port) || port < 1 || port > 65535) throw new Error("a connection needs a real port");
	// A filled account is a login. Its password is left for the SASL validation
	// the gateway runs, which names an empty one and the TLS requirement together.
	const account = (answers[ACCOUNT] ?? "").trim();
	const password = answers[PASSWORD] ?? "";
	// A password with no account would otherwise vanish without refusal and the
	// connection would open unauthenticated while its operator believes it
	// logged in. A credential is never silently dropped.
	if (account === "" && password !== "") {
		throw new Error("a password needs the account it logs into; fill Account or clear Password");
	}
	return {
		network: name,
		host,
		port,
		tls,
		nick,
		...(account === "" ? {} : { sasl: { account, password } }),
	};
}

/** Read an add-lease submission into IRC's channel name (with its leading #).
 *
 * The form draws the `#` as a fixed prefix, so the mark is completed when the
 * reader left it off and the typed characters are otherwise kept exactly:
 * `linux` and `#linux` both name `#linux`, and `##linux` stays the distinct
 * double-hash channel it names. Rewriting any given character would join a
 * different channel than the one the reader asked for. */
export function leaseChannelFromAnswers(raw: string): string {
	const answers = readBridgeAnswers(raw);
	const typed = (answers[CHANNEL] ?? "").trim();
	if (typed === "" || typed.replace(/^#+/, "") === "") throw new Error("a channel name is required");
	const channel = typed.startsWith("#") ? typed : `#${typed}`;
	if (channel.length > MAX_GATEWAY_NAME) {
		throw new Error(`a channel name stays within ${MAX_GATEWAY_NAME} characters`);
	}
	return channel;
}
