// The form IRC declares, and the one thing about it another module relies on.
//
// `IRC_SECRET_FIELDS` is what a caller splits a submission by, and this form is
// what a reader actually fills in. If the two ever named different fields, a
// password would be split into the half that gets written to disk, and nothing
// else in the tree would notice.

import {
	IRC_NICK_FIELD,
	IRC_PASSWORD_FIELD,
	IRC_SECRET_FIELDS,
	ircIdentityForm,
} from "../../irc/bridge/identity_form.ts";
import { bridgeFormHasSecret, bridgeFormSecretIds } from "../../lib/bridge/form.ts";
import type { IrcSeatView } from "../../irc/bridge/seat.ts";
import { assertEquals } from "../assert.ts";

const seat = (over: Partial<IrcSeatView> = {}): IrcSeatView => ({
	network: "Libera",
	phase: "rooms",
	nick: "ada",
	...over,
});

Deno.test("what IRC declares secret and what a caller splits by are the same fields", () => {
	const encrypted = ircIdentityForm(seat(), "irc.libera.chat:6697", true);
	assertEquals([...bridgeFormSecretIds(encrypted)], [...IRC_SECRET_FIELDS]);
	assertEquals([...IRC_SECRET_FIELDS], [IRC_PASSWORD_FIELD]);
});

Deno.test("without an encrypted path IRC asks for no password at all", () => {
	// Not offered and refused, but absent: the bridge will not take a SASL
	// password in the clear, and a field whose only outcome is that refusal
	// spends a reader's willingness to type one.
	const clear = ircIdentityForm(seat(), "irc.example.org:6667", false);
	assertEquals(bridgeFormHasSecret(clear), false);
	assertEquals([...bridgeFormSecretIds(clear)], []);
	assertEquals(clear.fields.map((field) => field.id), [IRC_NICK_FIELD]);
});

Deno.test("the scope IRC declares is its network, the same one a room states", () => {
	// One identity per network is the whole reason a sibling channel is reached
	// by an answer given elsewhere, so the form and the room have to agree.
	assertEquals(ircIdentityForm(seat({ network: "OFTC" }), "", true).scope, "OFTC");
});

Deno.test("a seat with nobody on IRC offers no way to disconnect", () => {
	// Nothing to stop, so the way out is absent rather than present and refused.
	assertEquals(ircIdentityForm(seat({ phase: "rooms" }), "", true).actions.map((action) => action.id), ["link"]);
	assertEquals(
		ircIdentityForm(seat({ phase: "linked" }), "", true).actions.map((action) => action.id),
		["link", "disconnect"],
	);
	// Both are remembered: "I am on Libera as ada" and "I am staying Rooms-only"
	// are each a state a reader chose and expects a reconnect to restore.
	assertEquals(
		ircIdentityForm(seat({ phase: "linked" }), "", true).actions.every((action) => action.remembered),
		true,
	);
});
