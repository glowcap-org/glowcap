// One Rooms member's own IRC projection.
//
// The roster is where the state is visible; its manage action opens this form.
// Credentials never enter the composer or browser store. The password is
// cleared before the room ask starts, while nick and account remain available
// to correct after a refusal.

import { useRef, useState } from "react";
import { Button } from "./Button.tsx";
import { Checkbox } from "./Checkbox.tsx";
import { Field } from "./Field.tsx";
import { identifierField } from "./field.ts";
import { useRoomsSession } from "./controller/session.ts";
import { Said } from "./Said.tsx";
import type { RoomConv, Standing } from "./types.ts";

type IrcStanding = NonNullable<Standing["irc"]>;

function phaseSaid(seat: IrcStanding, bridgeOrigin: string | null): string {
	const origin = bridgeOrigin == null ? "" : ` This room is bridged via ${bridgeOrigin}.`;
	switch (seat.state) {
		case "rooms":
			return "Rooms only. You are not present on IRC." + origin;
		case "connecting":
			return `Connecting to IRC as <${seat.nick}>…${origin}`;
		case "linked":
			return `Rooms and IRC are linked as <${seat.nick}>.${origin}`;
		case "failed":
			return `The IRC link for <${seat.nick}> failed. Retry it here or stay Rooms only.${origin}`;
	}
}

export function RoomIrcIdentity(
	{ conv, seat, connected, bridgeOrigin }: {
		conv: RoomConv;
		seat: IrcStanding;
		connected: boolean;
		bridgeOrigin: string | null;
	},
) {
	const session = useRoomsSession();
	const [nick, setNick] = useState(seat.nick);
	const [registered, setRegistered] = useState(false);
	const [account, setAccount] = useState(seat.nick);
	const [password, setPassword] = useState("");
	const [working, setWorking] = useState<"link" | "disconnect" | null>(null);
	const [why, setWhy] = useState("");
	const passwordInput = useRef<HTMLInputElement>(null);
	// A cancellation supersedes the pending link's local answer just as the room
	// supersedes its socket attempt. The older promise may still settle, but it
	// no longer owns this form's status line.
	const request = useRef(0);
	const linking = working === "link" || seat.state === "connecting";
	const disconnecting = working === "disconnect";
	const canSubmit = connected && !linking && !disconnecting && nick !== "" &&
		(!registered || (account !== "" && password !== ""));
	const refusal = why !== "" ? why : conv.ircIssue;
	const off = !connected || working !== null;

	const disconnect = () => {
		const own = ++request.current;
		if (passwordInput.current !== null) passwordInput.current.value = "";
		setPassword("");
		setWorking("disconnect");
		setWhy("");
		void session.disconnectIrcIdentity(conv.key).then((refused) => {
			if (request.current === own) setWhy(refused);
		}).finally(() => {
			if (request.current === own) setWorking(null);
		});
	};

	return (
		<div className="group well" role="group" aria-label="Your IRC identity">
			<p className="group-label">Your bridge state</p>
			<p className="hint" id="convcardIrcState">{phaseSaid(seat, bridgeOrigin)}</p>
			<form
				className="group"
				aria-busy={linking || disconnecting}
				onSubmit={(event) => {
					event.preventDefault();
					if (!canSubmit) return;
					const own = ++request.current;
					const handedPassword = registered ? password : "";
					const handedAccount = registered ? account : "";
					if (passwordInput.current !== null) passwordInput.current.value = "";
					setPassword("");
					setWorking("link");
					setWhy("");
					void session.connectIrcIdentity(conv.key, nick, handedAccount, handedPassword)
						.then((refused) => {
							if (request.current === own) setWhy(refused);
						})
						.finally(() => {
							if (request.current === own) setWorking(null);
						});
				}}
			>
				<Field id="convcardIrcNick" label="IRC nick">
					{(wiring) => (
						<input
							id={wiring.id}
							className="field"
							name="irc-nick"
							type="text"
							value={nick}
							disabled={off}
							{...identifierField}
							onChange={(event) => setNick(event.currentTarget.value)}
						/>
					)}
				</Field>
				<label className="check-row">
					<Checkbox
						id="convcardIrcRegistered"
						checked={registered}
						disabled={off}
						onChange={(event) => setRegistered(event.target.checked)}
					/>
					<span>Log in to a registered IRC account</span>
				</label>
				{registered && (
					<>
						<Field id="convcardIrcAccount" label="Account">
							{(wiring) => (
								<input
									id={wiring.id}
									className="field"
									name="irc-account"
									type="text"
									value={account}
									disabled={off}
									{...identifierField}
									onChange={(event) => setAccount(event.currentTarget.value)}
								/>
							)}
						</Field>
						<Field
							id="convcardIrcPassword"
							label="Password"
							hint="Sent once, cleared here immediately, and never remembered."
						>
							{(wiring) => (
								<input
									id={wiring.id}
									ref={passwordInput}
									className="field"
									name="irc-password"
									type="password"
									value={password}
									disabled={off}
									{...identifierField}
									aria-describedby={wiring.describedBy}
									onChange={(event) => setPassword(event.currentTarget.value)}
								/>
							)}
						</Field>
					</>
				)}
				<div className="actions">
					{seat.state !== "rooms" && (
						<Button
							id="convcardIrcDisconnect"
							type="button"
							variant="quiet"
							busy={disconnecting}
							disabled={!connected || disconnecting}
							onClick={disconnect}
						>
							{disconnecting
								? "Disconnecting…"
								: seat.state === "connecting"
								? "Cancel IRC link"
								: "Disconnect from IRC"}
						</Button>
					)}
					<Button id="convcardIrcLink" type="submit" busy={linking} disabled={!canSubmit}>
						{linking
							? "Linking to IRC…"
							: seat.state === "rooms"
							? "Link to IRC"
							: seat.state === "failed"
							? "Retry IRC link"
							: "Change IRC identity"}
					</Button>
				</div>
				{refusal !== "" && <Said id="convcardIrcWhy" kind="failure">{refusal}</Said>}
			</form>
		</div>
	);
}
