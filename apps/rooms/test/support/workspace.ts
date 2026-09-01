import {
	ROOMS_SESSION_STATE_VERSION,
	type RoomsWorkspaceState,
	WORKSPACE_STATE_VERSION,
} from "../../lib/rooms_state.ts";
import { registrationId } from "./registration.ts";
import { formatRoomsSturdyref, roomsLocator } from "../../lib/locator.ts";

export function fixtureSturdyref(authority: string, swiss: string): string {
	return formatRoomsSturdyref(roomsLocator(authority), swiss);
}

/** A fresh, complete workspace document for persistence and schema scenarios. */
export function workspaceFixture(): RoomsWorkspaceState {
	return {
		version: WORKSPACE_STATE_VERSION,
		controller: { kind: "local" },
		session: {
			version: ROOMS_SESSION_STATE_VERSION,
			directories: [{
				id: "ocapn://directory.id",
				locator: "ocapn://directory.id",
				home: true,
				nick: "ada",
				standing: null,
			}],
			conversations: [
				{
					kind: "room",
					id: "room-id",
					directory: "ocapn://directory.id",
					name: "general",
					held: false,
					link: fixtureSturdyref("ocapn://directory.id", "room-link"),
					steward: fixtureSturdyref("ocapn://directory.id", "moderator"),
					bridgeIntent: {
						scope: "Libera",
						action: "link",
						answers: { nick: "pancake", account: "acct" },
						secretsGiven: true,
					},
					standing: null,
					draft: "half written",
				},
				{
					kind: "direct",
					id: "dm-id",
					directory: "ocapn://directory.id",
					peer: "bo",
					peerRegistrationId: registrationId(1),
					closed: false,
					draft: "",
				},
			],
			invitations: [{
				kind: "room-link",
				id: "invite-1",
				directory: "ocapn://directory.id",
				locator: "ocapn://directory.id",
				nick: "ada",
				label: "private study",
				from: "bo",
				link: fixtureSturdyref("ocapn://directory.id", "invited-room"),
			}],
			active: "dm-id",
			standing: "",
			ignored: ["noise"],
			keepHistory: true,
			join: { room: "general", locator: "", nick: "ada" },
			dmMode: "webrtc",
			vizOverride: "",
			capabilities: {
				operations: [
					{ capability: "listeners", scope: "ocapn://directory.id", swiss: "listeners-swiss" },
					{ capability: "diagnostics", scope: "ocapn://directory.id", swiss: "diagnostics-swiss" },
					{ capability: "irc", scope: "ocapn://directory.id", swiss: "irc-swiss" },
					{ capability: "operator", scope: "ocapn://directory.id", swiss: "operator-swiss" },
					{ capability: "peering", scope: "ocapn://directory.id", swiss: "peering-swiss" },
					{ capability: "viz", scope: "ws://rooms.test/viz", swiss: "viz-swiss" },
				],
				archivePeer: fixtureSturdyref("ocapn://archive.iroh", "archive"),
			},
			peering: [],
		},
		view: {
			theme: "dark",
			notifyOn: true,
			railOpen: false,
			rosterOpen: true,
			settingsTab: "holdings",
			opsPane: "operator",
		},
	};
}
