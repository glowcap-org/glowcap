// The fixed peer of the verb-spine proof family: one plain-TCP listener on
// loopback that publishes `spine`, the object every binding's client projects
// and calls. It is the same known-good Deno side for all four
// clients, so a red run points at the client's binding rather than at a
// disagreement between two clients.
//
// `spine` answers five verbs, each shaped for one thing the client has to
// establish:
//
//   greet [who]  -> the string `hello, <who>`           (a far send settles)
//   list  []     -> the list ["alpha","beta","gamma"]   (op:index at the answer)
//   boxed []     -> the tagged record `cell` over ["cell-0","cell-1"]
//                                                       (op:untag, then op:index)
//   record []    -> the struct {name,rank}              (op:get at the answer)
//   mint  []     -> a fresh capability answering `ping` with "pong"
//                                                       (something to release)
//
// Run by `harness.ts`, which reads the `VERB-SPINE-PEER-READY <uri>` line and
// hands that locator to the client. The harness runs a second copy of this
// script and kills it, so the client also has a dead address to dial.

import { PStruct, tagged } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";

const server = await tcp.listen("127.0.0.1", 0);
console.log(`VERB-SPINE-PEER-READY ${server.uri}`);

for await (const accepted of server) {
	const session = accepted;
	session.publish("spine", (verb, args) => {
		switch (verb) {
			case "greet": {
				const who = typeof args[0] === "string" ? args[0] : "?";
				return `hello, ${who}`;
			}
			case "list":
				return ["alpha", "beta", "gamma"];
			case "boxed":
				return tagged("cell", ["cell-0", "cell-1"]);
			case "record":
				return new PStruct([["name", "spine-record"], ["rank", "two"]]);
			case "mint":
				return session.spawn((pinged) => {
					if (pinged !== "ping") throw new Error(`minted capability has no verb ${pinged}`);
					return "pong";
				});
			default:
				throw new Error(`spine has no verb ${verb}`);
		}
	});
	session.serve();
}
