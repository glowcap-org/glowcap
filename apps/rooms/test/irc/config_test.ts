import { parseIrcBridgeConfig } from "../../irc/bridge/config.ts";
import { assertEquals } from "../assert.ts";

function refusal(args: string[], password?: string): string {
	try {
		parseIrcBridgeConfig(args, () => password);
		return "";
	} catch (error) {
		return String(error);
	}
}

Deno.test("IRC bridge configuration defaults to a credential-free read-only service", () => {
	let environmentReads = 0;
	const config = parseIrcBridgeConfig([], () => {
		environmentReads += 1;
		return "must not be read";
	});
	assertEquals(
		[config.mode, config.tls, config.network, config.channel, config.ircPort, config.port, config.sasl],
		["read-only", true, "libera", "#ocapn", 6697, 0, undefined],
	);
	assertEquals(environmentReads, 0, "read-only startup touched the SASL secret environment");
});

Deno.test("IRC bridge two-way configuration requires TLS and an environment-only SASL secret", () => {
	const config = parseIrcBridgeConfig(
		["--mode=two-way", "--sasl-account=bridge-account", "--irc-nick=bridgebot"],
		(name) => name === "GLOWCAP_ROOMS_IRC_SASL_PASSWORD" ? "bridge-password" : undefined,
	);
	assertEquals(config.sasl, { account: "bridge-account", password: "bridge-password" });
	assertEquals(
		refusal(["--mode=two-way", "--sasl-account=bridge-account", "--tls=false"], "bridge-password").includes(
			"requires TLS",
		),
		true,
	);
	assertEquals(
		refusal(["--mode=two-way", "--sasl-account=bridge-account"]).includes("GLOWCAP_ROOMS_IRC_SASL_PASSWORD"),
		true,
	);
	assertEquals(
		refusal(["--mode=two-way", "--sasl-account=bridge-account", "--sasl-password=argv-secret"], "ignored")
			.includes("unknown IRC bridge option"),
		true,
		"the SASL password became an argv option",
	);
});

Deno.test("IRC bridge configuration refuses ambiguous or lossy options", () => {
	for (
		const args of [
			["--port=-1"],
			["--irc-port=0"],
			["--tls=yes"],
			["--mode=read-only", "--sasl-account=unused"],
			["--network=one", "--network=two"],
			["--irc-nick=9invalid"],
		]
	) {
		assertEquals(refusal(args).length > 0, true, `configuration was accepted: ${args.join(" ")}`);
	}
});
