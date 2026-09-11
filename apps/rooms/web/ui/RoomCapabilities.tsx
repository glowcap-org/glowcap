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
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsState } from "./hooks.ts";
import { Said } from "./Said.tsx";
import { locatorRefusal } from "./error_text.ts";
import type { RoomConv } from "./types.ts";
import { useChangeGroup, useCommitSettling } from "./commitment.tsx";
import { roomAuthorityToken } from "./application.ts";
import { RoomRecovery } from "./settings/RoomRecovery.tsx";
import { policyForRoomPreset, roomIsListed, type RoomPreset } from "./room_policy.ts";
import { RoomAccessControl } from "./RoomAccess.tsx";

type AuthorityAct = "drop-manager" | "drop-steward" | "revoke-steward" | "revoke-room" | "unregister-room";

interface AuthorityConfirmation {
	readonly act: AuthorityAct;
	readonly token: string;
}

export function RoomCapabilities(
	{ conv, available, authoritySource }: {
		conv: RoomConv;
		available: boolean;
		authoritySource: "local" | "foreign" | "bridge" | "unknown";
	},
) {
	const session = useRoomsSession();
	const browser = useRoomsBrowser();
	const directoryOperatorPossessed = useRoomsState((state) => state.operator !== null && state.homeDir === conv.dir);
	const directoryOperatorCanManage = directoryOperatorPossessed && authoritySource === "local";
	const [managerPasted, setManagerPasted] = useState("");
	const [takingManager, setTakingManager] = useState(false);
	const [managerSaid, setManagerSaid] = useState("");
	const [pasted, setPasted] = useState("");
	const [taking, setTaking] = useState<"claim" | "form" | null>(null);
	const [claimSaid, setClaimSaid] = useState("");
	const [takeSaid, setTakeSaid] = useState("");
	const [linking, setLinking] = useState(false);
	const [linkSaid, setLinkSaid] = useState("");
	const [confirming, setConfirming] = useState<AuthorityConfirmation | null>(null);
	const [authorityBusy, setAuthorityBusy] = useState<AuthorityAct | null>(null);
	const [authoritySaid, setAuthoritySaid] = useState<Readonly<Partial<Record<AuthorityAct, string>>>>({});
	const [policyBusy, setPolicyBusy] = useState(false);
	const [policySaid, setPolicySaid] = useState("");
	const commit = useCommitSettling();
	const authorityWorking = takingManager || taking !== null || linking || authorityBusy !== null;
	const held = conv.grants.has("steward");
	const managerHeld = conv.manager !== undefined;
	const canRevoke = managerHeld || directoryOperatorCanManage;
	const changePolicy = (next: RoomPreset) => {
		setPolicyBusy(true);
		setPolicySaid("");
		void session.setManagedRoomPolicy(conv.key, policyForRoomPreset(next)).then((refused) => {
			setPolicySaid(refused);
			if (refused === "") browser.toast("success", `Room access is now ${next}.`);
		}).finally(() => setPolicyBusy(false));
	};
	// Whether each paste field is on screen. One authority for it, because the
	// same answer decides two things that must agree: whether the field renders,
	// and whether what it holds counts as an unsaved change. Read apart, a route
	// that takes the capability some other way — minting one, recovering one —
	// leaves text behind a field that no longer exists, and the card then refuses
	// to close over changes a reader cannot see, find, or edit.
	const managerTakeShown = conv.manager == null && authoritySource !== "bridge";
	const stewardTakeShown = !held;
	useChangeGroup(`room-capabilities:${conv.key}`, {
		dirty: (managerTakeShown && managerPasted !== "") || (stewardTakeShown && pasted !== ""),
		discard: () => {
			if (takingManager || taking !== null || linking || authorityBusy !== null) {
				throw new Error("Wait for the room capability operation to finish.");
			}
			setManagerPasted("");
			setPasted("");
			setClaimSaid("");
			setTakeSaid("");
			setManagerSaid("");
		},
		settling: commit.current,
	});
	const take = (from: "claim" | "form", link?: string) => {
		commit.begin();
		setTaking(from);
		setClaimSaid("");
		setTakeSaid("");
		void session.stewardRoom(conv.key, link).then((refused) => {
			if (from === "claim") setClaimSaid(refused);
			else setTakeSaid(locatorRefusal(refused, "room moderator link"));
			if (refused === "" && from === "form") setPasted("");
		}).finally(() => {
			setTaking(null);
			commit.finish();
		});
	};
	const takeManager = () => {
		commit.begin();
		setTakingManager(true);
		setManagerSaid("");
		void session.managerRoom(conv.key, managerPasted).then((refused) => {
			setManagerSaid(locatorRefusal(refused, "room manager link"));
			if (refused === "") setManagerPasted("");
		}).finally(() => {
			setTakingManager(false);
			commit.finish();
		});
	};
	const recoverManager = () => {
		commit.begin();
		setTakingManager(true);
		setManagerSaid("");
		void session.recoverRoomManager(conv.key).then(setManagerSaid).finally(() => {
			setTakingManager(false);
			commit.finish();
		});
	};
	const createLink = () => {
		commit.begin();
		setLinking(true);
		setLinkSaid("");
		void session.createRoomLink(conv.key).then(setLinkSaid).finally(() => {
			setLinking(false);
			commit.finish();
		});
	};
	const changeAuthority = (
		confirmation: AuthorityConfirmation,
		work: () => Promise<string>,
		success: string,
	) => {
		commit.begin();
		setAuthorityBusy(confirmation.act);
		setAuthoritySaid((prior) => ({ ...prior, [confirmation.act]: "" }));
		void work().then((refused) => {
			setAuthoritySaid((prior) => ({ ...prior, [confirmation.act]: refused }));
			if (refused === "") {
				setConfirming(null);
				browser.toast("success", success);
			}
		}).finally(() => {
			setAuthorityBusy(null);
			commit.finish();
		});
	};
	const roomToken = conv.link === undefined ? null : roomAuthorityToken(conv.link);
	const managerToken = conv.manager === undefined ? null : roomAuthorityToken(conv.manager);
	const stewardToken = conv.steward === undefined ? null : roomAuthorityToken(conv.steward);
	const revokeAuthority = (kind: "room" | "steward", token: string) =>
		conv.manager != null
			? session.revokeManagedRoomAuthority(conv.key, kind, token)
			: session.revokeRoomAuthority(kind, token);

	return (
		<div className="group" role="group" aria-label="Room capabilities">
			<h3 className="well-title overline" id="convcardManagerTitle">Room management</h3>
			<div className="group well" role="group" aria-labelledby="convcardManagerTitle">
				{conv.manager == null
					? !managerTakeShown
						? (
							<p className="hint">
								The IRC bridge owns entry and moderator authority. It has no native room manager;
								administer the channel in IRC Operations.
							</p>
						)
						: (
							<form
								className="group"
								onSubmit={(event) => {
									event.preventDefault();
									if (managerPasted !== "") takeManager();
								}}
							>
								<Field
									id="convcardManagerTake"
									label="Take a shared room manager capability"
									hint="This manages this room's durable link and moderator capability. It does not grant entry or moderation by itself."
									said={managerSaid}
								>
									{(wiring) => (
										<input
											id={wiring.id}
											className="field"
											value={managerPasted}
											onChange={(event) => {
												setManagerPasted(event.currentTarget.value);
												setManagerSaid("");
											}}
											{...identifierField}
											placeholder="ocapn://…/s/…"
											aria-describedby={wiring.describedBy}
											aria-invalid={wiring.invalid}
											disabled={!available || authorityWorking}
										/>
									)}
								</Field>
								<div className="actions">
									<Button
										type="submit"
										busy={takingManager}
										disabled={!available || authorityWorking || managerPasted.trim() === ""}
									>
										Take manager capability
									</Button>
								</div>
								{directoryOperatorCanManage && (
									<>
										<p className="hint">
											This session also holds the directory operator capability, which can recover
											management for this exact room.
										</p>
										<div className="actions">
											<Button
												id="convcardManagerRecover"
												type="button"
												variant="quiet"
												busy={takingManager}
												disabled={!available || authorityWorking}
												onClick={recoverManager}
											>
												Recover manager capability
											</Button>
										</div>
									</>
								)}
								{directoryOperatorPossessed && !directoryOperatorCanManage && (
									<p className="hint">
										This room's source owns its management capability. This directory's operator
										cannot create it.
									</p>
								)}
							</form>
						)
					: (
						<>
							<CopyField
								id="convcardManager"
								text={conv.manager}
								label="Copy the room manager capability"
							/>
							<p className="hint">
								Manages the entry link and moderator. It does not grant entry or moderation. Sharing it
								delegates management. The directory operator can recover a lost copy.
							</p>
							{managerToken !== null && (
								<>
									{confirming?.act === "drop-manager" && confirming.token === managerToken
										? (
											<Confirm
												label="Discard room manager capability"
												say="This session discards its manager capability. Other copies continue to work."
												keep="Keep management"
												commit="Discard capability"
												busy={authorityBusy === "drop-manager"}
												onKeep={() => setConfirming(null)}
												onCommit={() =>
													changeAuthority(
														confirming,
														() => session.dropRoomManager(conv.key, confirming.token),
														"This session discarded its room manager capability.",
													)}
											/>
										)
										: confirming?.act === "unregister-room" && confirming.token === managerToken
										? (
											<Confirm
												label={`Release the registered name #${conv.id}`}
												say="The public name and its current public entrance are released. The room, its current members, and the capabilities you hold remain. You can register the room again by changing its access."
												keep="Keep registration"
												commit="Release registered name"
												busy={authorityBusy === "unregister-room"}
												onKeep={() => setConfirming(null)}
												onCommit={() =>
													changeAuthority(
														confirming,
														() => session.unregisterManagedRoom(conv.key),
														`Released the registered room name #${conv.id}.`,
													)}
											/>
										)
										: (
											<div className="actions">
												<Button
													id="convcardManagerDropAsk"
													variant="quiet"
													disabled={authorityWorking}
													onClick={() =>
														setConfirming({ act: "drop-manager", token: managerToken })}
												>
													Discard manager…
												</Button>
												{roomIsListed(conv.policy) && (
													<Button
														id="convcardUnregisterAsk"
														variant="quiet"
														disabled={authorityWorking}
														onClick={() =>
															setConfirming({
																act: "unregister-room",
																token: managerToken,
															})}
													>
														Release registered name…
													</Button>
												)}
											</div>
										)}
									{authoritySaid["unregister-room"] && (
										<Said kind="failure">{authoritySaid["unregister-room"]}</Said>
									)}
								</>
							)}
						</>
					)}
			</div>
			{conv.manager != null && (
				<RoomAccessControl
					policy={conv.policy}
					busy={policyBusy}
					disabled={!available || authorityWorking}
					said={policySaid}
					onChange={changePolicy}
				/>
			)}
			{!available && <RoomRecovery conv={conv} blocked={authorityWorking} />}
			<h3 className="well-title overline" id="convcardRoomLinkTitle">Room entry link</h3>
			<div className="group well" role="group" aria-labelledby="convcardRoomLinkTitle">
				{conv.link === undefined
					? (
						<>
							<p className="hint" id="convcardRoomLinkHint">
								{managerHeld
									? "Create durable bearer authority to enter this exact room across server restarts. Anyone with the entry link can enter and pass it on. It grants neither moderation nor history."
									: authoritySource === "bridge"
									? "Save the IRC bridge's source-owned entry link to return to this exact publication."
									: "This session holds no room entry link. A room manager can create one and share it with this session."}
							</p>
							{(managerHeld || authoritySource === "bridge") && (
								<div className="actions">
									<Button
										id="convcardCreateRoomLink"
										busy={linking}
										disabled={!available || authorityWorking}
										aria-describedby="convcardRoomLinkHint"
										onClick={createLink}
									>
										{linking
											? authoritySource === "bridge"
												? "Saving entry link…"
												: "Creating entry link…"
											: authoritySource === "bridge"
											? "Save entry link"
											: "Create entry link"}
									</Button>
								</div>
							)}
							{linkSaid !== "" && <Said id="convcardRoomLinkSaid" kind="failure">{linkSaid}</Said>}
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
							{canRevoke && roomToken !== null && (
								<>
									{confirming?.act === "revoke-room" && confirming.token === roomToken
										? (
											<Confirm
												label="Revoke this room entry link"
												say="This link and the current moderator capability stop working for everyone immediately. Current room memberships remain, and fresh authority can be created afterward."
												keep="Keep link"
												commit="Revoke room authority"
												busy={authorityBusy === "revoke-room"}
												onKeep={() => setConfirming(null)}
												onCommit={() =>
													changeAuthority(
														confirming,
														() => revokeAuthority("room", confirming.token),
														"Revoked the room entry link and its moderator capability.",
													)}
											/>
										)
										: (
											<div className="actions">
												<Button
													id="convcardRoomLinkRevokeAsk"
													variant="quiet"
													disabled={authorityWorking}
													onClick={() =>
														setConfirming({ act: "revoke-room", token: roomToken })}
												>
													Revoke link…
												</Button>
											</div>
										)}
									{authoritySaid["revoke-room"] && (
										<Said kind="failure">{authoritySaid["revoke-room"]}</Said>
									)}
								</>
							)}
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
							: managerHeld
							? "Available through the held room manager"
							: "Not held by this tab"}
					</dd>
				</dl>
				{stewardTakeShown && (conv.steward !== undefined || managerHeld) && (
					<div className="actions">
						<Button
							id="convcardStewardClaim"
							/* The alternative route, beside the paste form's own submit below:
							   the room manager's well pairs them the same way, its form
							   carrying the solid act and `convcardManagerRecover` the quiet
							   one. Two solid buttons in one well ask the reader to choose
							   between two shouts. */
							variant="quiet"
							busy={taking === "claim"}
							disabled={!available || authorityWorking}
							onClick={() => take("claim", conv.steward)}
						>
							{taking === "claim"
								? conv.steward === undefined
									? "Issuing moderator capability…"
									: "Taking retained capability…"
								: conv.steward === undefined
								? "Issue moderator capability"
								: "Take retained capability"}
						</Button>
					</div>
				)}
				{claimSaid !== "" && <Said id="convcardStewardSaid" kind="failure">{claimSaid}</Said>}
				{stewardTakeShown && (
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
									disabled={!available || authorityWorking}
								/>
							)}
						</Field>
						<div className="actions">
							<Button
								type="submit"
								busy={taking === "form"}
								disabled={!available || authorityWorking || pasted.trim() === ""}
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
						{stewardToken !== null && (
							<>
								{confirming?.act === "drop-steward" && confirming.token === stewardToken
									? (
										<Confirm
											label="Discard room moderator capability"
											say="This session discards its moderator capability. Other copies still work, and a current copy can be taken again later."
											keep="Keep capability"
											commit="Discard capability"
											busy={authorityBusy === "drop-steward"}
											onKeep={() => setConfirming(null)}
											onCommit={() =>
												changeAuthority(
													confirming,
													() => session.dropRoomModerator(conv.key, confirming.token),
													"This session discarded its room moderator capability.",
												)}
										/>
									)
									: confirming?.act === "revoke-steward" && confirming.token === stewardToken
									? (
										<Confirm
											label="Revoke room moderation for everyone"
											say="Every copy stops moderating this room immediately, including capabilities already in use. The room entry link and current memberships remain."
											keep="Keep capability"
											commit="Revoke moderator capability"
											busy={authorityBusy === "revoke-steward"}
											onKeep={() => setConfirming(null)}
											onCommit={() =>
												changeAuthority(
													confirming,
													() => revokeAuthority("steward", confirming.token),
													"Revoked the room moderator capability for everyone.",
												)}
										/>
									)
									: (
										<div className="actions" data-stack-narrow>
											<Button
												id="convcardStewardDropAsk"
												variant="quiet"
												disabled={authorityWorking}
												onClick={() =>
													setConfirming({ act: "drop-steward", token: stewardToken })}
											>
												Discard moderator…
											</Button>
											{canRevoke && (
												<Button
													id="convcardStewardRevokeAsk"
													variant="quiet"
													disabled={authorityWorking}
													onClick={() =>
														setConfirming({ act: "revoke-steward", token: stewardToken })}
												>
													Revoke for everyone…
												</Button>
											)}
										</div>
									)}
								{authoritySaid["drop-steward"] && (
									<Said kind="failure">{authoritySaid["drop-steward"]}</Said>
								)}
								{authoritySaid["revoke-steward"] && (
									<Said kind="failure">{authoritySaid["revoke-steward"]}</Said>
								)}
							</>
						)}
					</>
				)}
			</div>
		</div>
	);
}
