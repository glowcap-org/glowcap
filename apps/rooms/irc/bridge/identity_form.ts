// The form IRC asks Rooms to draw for one reader's own identity.
//
// This is the same form the browser used to build: a nick, a checkbox for a
// registered account, and the account and password behind it. What changed is
// who decides. The browser knew IRC had four link states and what each was
// called; now IRC says so, and a second bridge describes something else without
// the browser being rebuilt.
//
// Declared for the state it is in rather than as a template. The bridge knows
// which state a seat is in when it is asked, so the labels here are the ones
// for right now.

import type { BridgeForm } from "../../lib/bridge/form.ts";
import type { IrcSeatView } from "./seat.ts";

/** Where a seat stands, in IRC's words, including where the connection reaches
 * when a bridge knows. A reader deciding whether to hand over a password is
 * owed the endpoint it will be handed to. */
function said(view: IrcSeatView, origin: string, tls: boolean): string {
	const reaches = origin === "" ? "" : ` The connection reaches ${origin}.`;
	// A cleartext connection cannot carry a password safely, so the
	// registered-account login is not drawn on it. Say so, rather than leave a
	// reader looking for a field that was silently withheld.
	const login = tls
		? ""
		: ` Logging in to a registered ${view.network} account needs an encrypted connection, so it is not offered here.`;
	switch (view.phase) {
		case "rooms":
			return `Rooms only. You are not present on ${view.network}.` + reaches + login;
		case "connecting":
			return `Connecting to ${view.network} as <${view.nick}>…` + reaches + login;
		case "linked":
			return `Rooms and ${view.network} are linked as <${view.nick}>.` + reaches + login;
		case "failed":
			return `The ${view.network} link for <${view.nick}> failed. Retry it here or stay Rooms only.` + reaches +
				login;
	}
}

/** What pressing the commitment is called, which is a different act in each
 * state even though it is one verb underneath. */
function commit(view: IrcSeatView): string {
	if (view.phase === "rooms") return "Link to IRC";
	if (view.phase === "failed") return "Retry IRC link";
	return "Change IRC identity";
}

export const IRC_LINK_ACTION = "link";
export const IRC_DISCONNECT_ACTION = "disconnect";
export const IRC_NICK_FIELD = "nick";
export const IRC_REGISTERED_FIELD = "registered";
export const IRC_ACCOUNT_FIELD = "account";
export const IRC_PASSWORD_FIELD = "password";

/** Which of IRC's fields Rooms must not keep.
 *
 * The form below builds its `secret` field from this, and a caller splitting a
 * submission reads the same set, so the two cannot come to differ about which
 * answer is a password. See `splitBridgeSubmission`. */
export const IRC_SECRET_FIELDS: ReadonlySet<string> = new Set([IRC_PASSWORD_FIELD]);

/** The form for this seat as it stands.
 *
 * `tls` decides whether the registered-account login is drawn: over an
 * encrypted path the nick sits above a toggle that reveals an account and
 * password, exactly as the standalone IRC page offered. A cleartext connection
 * cannot carry a password safely, so those fields are not drawn and `said`
 * explains their absence rather than leaving a reader to hunt for them. */
export function ircIdentityForm(view: IrcSeatView, origin: string, tls: boolean): BridgeForm {
	return {
		// One identity per network, shared by every channel on it: linking in one
		// room links in all of them, and a password typed once serves the rest.
		scope: view.network,
		title: `Your ${view.network} identity`,
		said: said(view, origin, tls),
		fields: [
			{ kind: "text", id: IRC_NICK_FIELD, label: "IRC nick", value: view.nick, required: true },
			...(tls
				? [{
					kind: "toggle" as const,
					id: IRC_REGISTERED_FIELD,
					label: "Log in to a registered IRC account",
					on: false,
					reveals: [
						{ kind: "text" as const, id: IRC_ACCOUNT_FIELD, label: "Account", required: true },
						{ kind: "secret" as const, id: IRC_PASSWORD_FIELD, label: "Password", required: true },
					],
				}]
				: []),
		],
		actions: [
			{
				id: IRC_LINK_ACTION,
				label: commit(view),
				busyLabel: "Linking to IRC…",
				tone: "primary",
				remembered: true,
			},
			// Nothing to stop when nobody is on IRC, so the way out is absent
			// rather than present and refused.
			...(view.phase === "rooms" ? [] : [{
				id: IRC_DISCONNECT_ACTION,
				label: view.phase === "connecting" ? "Cancel IRC link" : `Disconnect from ${view.network}`,
				busyLabel: "Disconnecting…",
				tone: "quiet" as const,
				// Staying Rooms-only is a choice too, and a reconnect that quietly
				// put somebody back on IRC would be overriding it.
				remembered: true,
				// Ending an established or standing link takes a member off IRC, so
				// it asks first. Cancelling a link still connecting has nothing to
				// take away, so it acts at once.
				...(view.phase === "connecting" ? {} : {
					confirm: {
						say: `Disconnect from ${view.network}? You will leave it and stay Rooms only until you link again.`,
						keep: "Stay linked",
						commit: `Disconnect from ${view.network}`,
					},
				}),
			}]),
		],
	};
}
