import { parseIrcFrontConfig } from "../../irc/front/config.ts";
import { assertEquals } from "../assert.ts";

Deno.test("IRC front defaults to a loopback cleartext listener and private DM endpoint", () => {
	assertEquals(parseIrcFrontConfig([]), {
		directory: "127.0.0.1:9099",
		bind: "127.0.0.1",
		port: 6667,
		serverName: "rooms.local",
		dm: { transport: "noise", bind: "127.0.0.1", port: 0 },
	});
});

Deno.test("IRC front exposes explicit Goblins-readable and authenticated DM postures", () => {
	assertEquals(parseIrcFrontConfig(["--dm-transport=tcp"]).dm, {
		transport: "tcp",
		bind: "127.0.0.1",
		port: 0,
	});
	assertEquals(parseIrcFrontConfig(["--dm-transport=iroh"]).dm, { transport: "iroh" });
	for (
		const args of [
			["--dm-transport=tcp", "--dm-bind=0.0.0.0", "--dm-announce-host=rooms.example"],
			["--dm-transport=iroh", "--dm-port=1"],
		]
	) {
		let refusal = "";
		try {
			parseIrcFrontConfig(args);
		} catch (error) {
			refusal = String(error);
		}
		assertEquals(refusal.length > 0, true, `accepted ${args.join(" ")}`);
	}
});

Deno.test("IRC front requires TLS when exposed beyond loopback", () => {
	let refusal = "";
	try {
		parseIrcFrontConfig(["--bind=0.0.0.0"]);
	} catch (error) {
		refusal = String(error);
	}
	assertEquals(refusal.includes("requires --tls-cert and --tls-key"), true, refusal);
	assertEquals(
		parseIrcFrontConfig([
			"--bind=0.0.0.0",
			"--tls-cert=/run/rooms/cert.pem",
			"--tls-key=/run/rooms/key.pem",
			"--dm-bind=0.0.0.0",
			"--dm-announce-host=rooms.example",
		]).tls,
		{ certPath: "/run/rooms/cert.pem", keyPath: "/run/rooms/key.pem" },
	);
});

Deno.test("IRC front rejects ambiguous and malformed options", () => {
	for (
		const args of [
			["--port=-1"],
			["--server-name=bad server"],
			["--tls-cert=cert.pem"],
			["--dm-bind=::"],
			["--port=1", "--port=2"],
			["--unknown=yes"],
		]
	) {
		let refused = false;
		try {
			parseIrcFrontConfig(args);
		} catch {
			refused = true;
		}
		assertEquals(refused, true, `accepted ${args.join(" ")}`);
	}
});
