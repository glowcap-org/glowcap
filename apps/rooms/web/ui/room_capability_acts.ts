// The acts on a room card's capabilities, apart from the wells that draw them.
//
// Taking, recovering, and discarding a manager or moderator, minting and
// revoking the entry link, and changing the room's access all share one
// settling commitment and one busy flag, because the card refuses to close
// over a paste in flight and refuses a second act while one is answering.
// That shared state is the subject here; `RoomCapabilities.tsx` is the three
// wells that read it.

import { useState } from "react";
import { roomAccessNow, roomCapabilityWait } from "../../lib/text/room_authority.ts";
import { useRoomsSession } from "./controller/session.ts";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsState } from "./hooks.ts";
import { actionRefusal, locatorRefusal } from "./error_text.ts";
import type { RoomConv } from "./types.ts";
import { useChangeGroup, useCommitSettling } from "./commitment.tsx";
import { policyForRoomPreset, type RoomPreset } from "./room_policy.ts";

export type AuthorityAct = "drop-manager" | "drop-steward" | "revoke-steward" | "revoke-room" | "unregister-room";

export interface AuthorityConfirmation {
	readonly act: AuthorityAct;
	readonly token: string;
}

export function useRoomCapabilityActs(
	conv: RoomConv,
	authoritySource: "local" | "foreign" | "bridge" | "unknown",
) {
	const session = useRoomsSession();
	const browser = useRoomsBrowser();
	const directoryOperatorPossessed = useRoomsState((state) => state.operator !== null && state.homeDir === conv.dir);
	const directoryOperatorCanManage = directoryOperatorPossessed && authoritySource === "local";
	const [managerPasted, setManagerPasted] = useState("");
	const [takingManager, setTakingManager] = useState<"take" | "recover" | null>(null);
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
	// Every act here changes the same room's authority or access, so while one
	// runs the others wait rather than race it.
	const authorityWorking = takingManager !== null || taking !== null || linking || authorityBusy !== null ||
		policyBusy;
	const held = conv.grants.has("steward");
	const managerHeld = conv.managerToken !== undefined;
	const canRevoke = managerHeld || directoryOperatorCanManage;
	const changePolicy = (next: RoomPreset) => {
		if (authorityWorking) return;
		setPolicyBusy(true);
		setPolicySaid("");
		void actionRefusal(() => session.setManagedRoomPolicy(conv.key, policyForRoomPreset(next))).then((refused) => {
			setPolicySaid(refused);
			if (refused === "") browser.toast("success", roomAccessNow(next));
		}).finally(() => setPolicyBusy(false));
	};
	// Whether each paste field is on screen. One authority for it, because the
	// same answer decides two things that must agree: whether the field renders,
	// and whether what it holds counts as an unsaved change. Read apart, a route
	// that takes the capability some other way (minting one, recovering one)
	// leaves text behind a field that no longer exists, and the card then refuses
	// to close over changes a reader cannot see, find, or edit.
	const managerTakeShown = conv.managerToken == null && authoritySource !== "bridge";
	const stewardTakeShown = !held;
	useChangeGroup(`room-capabilities:${conv.key}`, {
		dirty: (managerTakeShown && managerPasted !== "") || (stewardTakeShown && pasted !== ""),
		discard: () => {
			if (authorityWorking) {
				throw new Error(roomCapabilityWait);
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
		void actionRefusal(() => session.stewardRoom(conv.key, link)).then((refused) => {
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
		setTakingManager("take");
		setManagerSaid("");
		void actionRefusal(() => session.managerRoom(conv.key, managerPasted)).then((refused) => {
			setManagerSaid(locatorRefusal(refused, "room manager link"));
			if (refused === "") setManagerPasted("");
		}).finally(() => {
			setTakingManager(null);
			commit.finish();
		});
	};
	const recoverManager = () => {
		commit.begin();
		setTakingManager("recover");
		setManagerSaid("");
		void actionRefusal(() => session.recoverRoomManager(conv.key)).then(setManagerSaid).finally(() => {
			setTakingManager(null);
			commit.finish();
		});
	};
	const createLink = () => {
		commit.begin();
		setLinking(true);
		setLinkSaid("");
		void actionRefusal(() => session.createRoomLink(conv.key)).then(setLinkSaid).finally(() => {
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
		void actionRefusal(work).then((refused) => {
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
	const roomToken = conv.linkToken ?? null;
	const managerToken = conv.managerToken ?? null;
	const stewardToken = conv.stewardToken ?? null;
	const revokeAuthority = (kind: "room" | "steward", token: string) =>
		conv.managerToken != null
			? session.revokeManagedRoomAuthority(conv.key, kind, token)
			: session.revokeRoomAuthority(kind, token);
	return {
		directoryOperatorPossessed,
		directoryOperatorCanManage,
		managerPasted,
		setManagerPasted,
		takingManager,
		managerSaid,
		setManagerSaid,
		pasted,
		setPasted,
		taking,
		claimSaid,
		takeSaid,
		setTakeSaid,
		linking,
		linkSaid,
		confirming,
		setConfirming,
		authorityBusy,
		authoritySaid,
		policyBusy,
		policySaid,
		authorityWorking,
		held,
		managerHeld,
		canRevoke,
		changePolicy,
		managerTakeShown,
		stewardTakeShown,
		take,
		takeManager,
		recoverManager,
		createLink,
		changeAuthority,
		roomToken,
		managerToken,
		stewardToken,
		revokeAuthority,
	};
}
