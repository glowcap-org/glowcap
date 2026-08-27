// A room's moderation authorities and the operations they make possible.
//
// The application-wide Operations page supplied the useful shape, not this
// layout: possession is a visible fact, taking a capability is an explicit
// act, and only operations backed by a capability actually held are offered.
// A local room moderator can remove members. An IRC gateway holder can retire
// one exact bridge it administers. The tab shows only the powers this session
// actually holds, without treating the broader gateway as room stewardship.

import { useState } from "react";
import { Button } from "./Button.tsx";
import { Confirm } from "./Confirm.tsx";
import { CopyField } from "./Copy.tsx";
import { Field } from "./Field.tsx";
import { identifierField } from "./field.ts";
import { useRoomsSession } from "./controller/session.ts";
import { Said } from "./Said.tsx";
import { locatorRefusal } from "./error_text.ts";
import type { IrcBridgeRow, RoomConv } from "./types.ts";

function membersToModerate(conv: RoomConv, you: string): string[] {
	return [...conv.members]
		.filter(([name, standing]) => standing.online && name !== you)
		.map(([name]) => name)
		.sort((a, b) => a.localeCompare(b));
}

export function RoomCapabilities(
	{ conv, available }: { conv: RoomConv; available: boolean },
) {
	const session = useRoomsSession();
	const [pasted, setPasted] = useState("");
	const [taking, setTaking] = useState<"claim" | "form" | null>(null);
	const [claimSaid, setClaimSaid] = useState("");
	const [takeSaid, setTakeSaid] = useState("");
	const [linking, setLinking] = useState(false);
	const [linkSaid, setLinkSaid] = useState("");
	const held = conv.grants.has("steward");
	const canClaim = conv.stewardClaimable;
	const take = (from: "claim" | "form", link?: string) => {
		setTaking(from);
		setClaimSaid("");
		setTakeSaid("");
		void session.stewardRoom(conv.key, link).then((refused) => {
			if (from === "claim") setClaimSaid(refused);
			else setTakeSaid(locatorRefusal(refused, "room moderator link"));
			if (refused === "" && from === "form") setPasted("");
		}).finally(() => setTaking(null));
	};
	const createLink = () => {
		setLinking(true);
		setLinkSaid("");
		void session.createRoomLink(conv.key).then(setLinkSaid).finally(() => setLinking(false));
	};

	return (
		<div className="group" role="group" aria-label="Room capabilities">
			<h3 className="well-title overline" id="convcardRoomLinkTitle">Room link</h3>
			<div className="group well" role="group" aria-labelledby="convcardRoomLinkTitle">
				{conv.link === undefined
					? (
						<>
							<p className="hint" id="convcardRoomLinkHint">
								A durable bearer link reaches this exact room across restarts of the room server. Anyone
								who has it can enter and pass it on. It does not grant moderation or keep message
								history.
							</p>
							<div className="actions">
								<Button
									id="convcardCreateRoomLink"
									busy={linking}
									disabled={!available}
									aria-describedby="convcardRoomLinkHint"
									onClick={createLink}
								>
									{linking ? "Creating room link…" : "Create room link"}
								</Button>
							</div>
							<Said id="convcardRoomLinkSaid" kind="failure">{linkSaid}</Said>
						</>
					)
					: (
						<>
							<CopyField
								id="convcardRoomLink"
								text={conv.link}
								label="Copy this room's durable link"
							/>
							<p className="hint" id="convcardRoomLinkHint">
								This durable bearer link reaches this exact room across restarts of the room server.
								Anyone who has it can enter and pass it on. It does not grant moderation or keep message
								history.
							</p>
						</>
					)}
			</div>
			<h3 className="well-title overline" id="convcardRoomAuthorityTitle">Room authority</h3>
			<div className="group well" role="group" aria-labelledby="convcardRoomAuthorityTitle">
				<dl className="dirfacts">
					<dt>Set the topic</dt>
					<dd>{conv.grants.has("topic") ? "Held by this membership" : "Not offered by this room"}</dd>
					<dt>Moderate membership</dt>
					<dd>
						{held
							? "Held by this tab"
							: conv.steward !== undefined
							? "Retained, but not held on this connection"
							: canClaim
							? "Available to this room's creator connection"
							: "Not held by this tab"}
					</dd>
				</dl>
				{!held && (conv.steward !== undefined || canClaim) && (
					<div className="actions">
						<Button
							id="convcardStewardClaim"
							busy={taking === "claim"}
							disabled={!available || taking !== null}
							onClick={() => take("claim", conv.steward)}
						>
							{taking === "claim"
								? conv.steward === undefined
									? "Claiming moderator capability…"
									: "Taking retained capability…"
								: conv.steward === undefined
								? "Claim moderator capability"
								: "Take retained capability"}
						</Button>
					</div>
				)}
				{claimSaid !== "" && <Said id="convcardStewardSaid" kind="failure">{claimSaid}</Said>}
				{!held && (
					<form
						className="group"
						onSubmit={(event) => {
							event.preventDefault();
							if (pasted !== "") take("form", pasted);
						}}
					>
						<Field
							id="convcardStewardTake"
							label="Take a shared room moderator capability"
							hint="Paste the room moderator sturdyref somebody handed you."
							said={takeSaid}
						>
							{(wiring) => (
								<input
									id={wiring.id}
									className="field"
									name="steward"
									type="text"
									enterKeyHint="go"
									value={pasted}
									onChange={(event) => {
										setPasted(event.target.value);
										setTakeSaid("");
									}}
									{...identifierField}
									placeholder="ocapn://…/s/…"
									aria-describedby={wiring.describedBy}
									aria-invalid={wiring.invalid}
									disabled={!available || taking !== null}
								/>
							)}
						</Field>
						<div className="actions">
							<Button
								type="submit"
								busy={taking === "form"}
								disabled={!available || taking !== null || pasted === ""}
							>
								{taking === "form" ? "Taking capability…" : "Take capability"}
							</Button>
						</div>
					</form>
				)}
				{conv.steward !== undefined && (
					<>
						<p className="field-label" id="convcardStewardKind">Room moderator capability</p>
						<CopyField
							id="convcardSteward"
							text={conv.steward}
							label="Copy the room moderator capability"
						/>
						<p className="hint" id="convcardStewardHint">
							This is bearer authority to moderate this room. Share it only with somebody you want to
							moderate the room.
						</p>
					</>
				)}
			</div>
		</div>
	);
}

/** Operations exposed by the live capabilities this session actually holds.
 * Member removal answers to a room moderator; unbridging answers to the IRC
 * gateway for this directory. Neither authority stands in for the other. */
export function RoomModeration(
	{ conv, you, available, administeredBridge }: {
		conv: RoomConv;
		you: string;
		available: boolean;
		administeredBridge: IrcBridgeRow | null;
	},
) {
	const session = useRoomsSession();
	const [asking, setAsking] = useState<string | null>(null);
	const [working, setWorking] = useState<string | null>(null);
	const [askWhy, setAskWhy] = useState<Readonly<Record<string, string>>>({});
	const [confirmUnbridge, setConfirmUnbridge] = useState(false);
	const [unbridging, setUnbridging] = useState(false);
	const [unbridgeWhy, setUnbridgeWhy] = useState("");
	const canRemoveMembers = available && conv.grants.has("steward");
	if (!canRemoveMembers && administeredBridge === null) return null;
	const targets = membersToModerate(conv, you);
	const confirming = asking !== null && targets.includes(asking) ? asking : null;
	return (
		<div className="group" role="group" aria-label="Room moderation">
			{canRemoveMembers && (
				<>
					<h3 className="well-title overline" id="convcardMemberModerationTitle">Members</h3>
					<div className="group well" role="group" aria-labelledby="convcardMemberModerationTitle">
						<p className="hint">
							Asking somebody to leave does not ban them. A room link or public room name still lets them
							return.
						</p>
						{targets.length === 0
							? <p className="empty">Nobody else is here right now.</p>
							: (
								<ul className="entries">
									{targets.map((name) => (
										<li className="entry" key={name}>
											<div className="entry-head">
												<span className="entry-name">{name}</span>
												<div className="actions">
													<Button
														variant="quiet"
														disabled={confirming === name}
														onClick={() => setAsking(name)}
													>
														Ask to leave…
													</Button>
												</div>
											</div>
											{confirming === name && (
												<Confirm
													label={"Ask " + name + " to leave"}
													say={"Ask " + name +
														" to leave the room? They can come back by its name or link."}
													keep="Keep here"
													commit={working === name ? "Asking to leave…" : "Ask to leave"}
													commitId="convcardKickConfirm"
													busy={working === name}
													onKeep={() => setAsking(null)}
													onCommit={() => {
														setWorking(name);
														setAskWhy((prior) => ({ ...prior, [name]: "" }));
														void session.askRoomMemberOut(conv.key, name).then(
															(refused) => {
																setAskWhy((prior) => ({ ...prior, [name]: refused }));
																if (refused === "") setAsking(null);
															},
														).finally(() => setWorking(null));
													}}
												/>
											)}
											{askWhy[name] != null && askWhy[name] !== "" && (
												<Said kind="failure">{askWhy[name]}</Said>
											)}
										</li>
									))}
								</ul>
							)}
					</div>
				</>
			)}
			{administeredBridge !== null && (
				<>
					<h3 className="well-title overline" id="convcardBridgeModerationTitle">IRC bridge</h3>
					<div className="group well" role="group" aria-labelledby="convcardBridgeModerationTitle">
						<dl className="dirfacts">
							<dt>Channel</dt>
							<dd>{administeredBridge.network}/{administeredBridge.channel}</dd>
							<dt>Authority</dt>
							<dd>IRC gateway capability held by this session</dd>
						</dl>
						<p className="hint" id="convcardUnbridgeHint">
							Unbridging closes every IRC seat and removes this room from the directory. The IRC channel
							itself stays as it is.
						</p>
						{confirmUnbridge
							? (
								<Confirm
									label="Unbridge this room from IRC"
									say="Unbridge this room? Every IRC seat closes and the room leaves the directory."
									keep="Keep bridge"
									commit={unbridging ? "Unbridging…" : "Unbridge room"}
									commitId="convcardUnbridgeConfirm"
									busy={unbridging}
									onKeep={() => setConfirmUnbridge(false)}
									onCommit={() => {
										setUnbridging(true);
										setUnbridgeWhy("");
										void session.partIrc(administeredBridge.network, administeredBridge.channel)
											.then((refused) => setUnbridgeWhy(refused))
											.finally(() => setUnbridging(false));
									}}
								/>
							)
							: (
								<div className="actions">
									<Button
										id="convcardUnbridgeAsk"
										variant="quiet"
										onClick={() => setConfirmUnbridge(true)}
									>
										Unbridge from IRC…
									</Button>
								</div>
							)}
						<Said id="convcardUnbridgeWhy" kind="failure">{unbridgeWhy}</Said>
					</div>
				</>
			)}
		</div>
	);
}
