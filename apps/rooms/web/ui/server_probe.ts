// Live locator reads and browser permission guidance for the selected Rooms server.
import * as z from "zod/mini";
import { applicationModule, applicationProjection } from "./application.ts";
import { localNetworkBlock, type LocalNetworkRefusal } from "./local_network.ts";

const ServerLocatorReplySchema = z.discriminatedUnion("kind", [
	z.object({ kind: z.literal("answers"), directory: z.string() }),
	z.object({ kind: z.literal("elsewhere") }),
	z.object({ kind: z.literal("unavailable") }),
	z.object({ kind: z.literal("timedOut") }),
]);
export type ServerLocatorReply = z.infer<typeof ServerLocatorReplySchema>;
export async function locateRoomsServer(base: string): Promise<ServerLocatorReply> {
	const reply = await applicationModule().locateRoomsServer(base);
	return applicationProjection(reply, ServerLocatorReplySchema, "locator reply");
}

/** What a server at `base` says to this page before anything is saved, or
 * `blocked`: this browser stands between a page from the public internet and
 * a server on the person's own computer or network until they allow it. */
export type ServerProbe = ServerLocatorReply | { readonly kind: "blocked"; readonly permission: LocalNetworkRefusal };

/** Report the application’s locator result, with browser permission advice
 * when a failed read crossed into the local network. */
export async function probeServer(
	base: string,
	read = locateRoomsServer,
	blocked = localNetworkBlock,
): Promise<ServerProbe> {
	const reply = await read(base);
	if (reply.kind !== "unavailable" && reply.kind !== "timedOut") return reply;
	const permission = await blocked(new URL(base));
	return permission === "prompt" || permission === "denied" ? { kind: "blocked", permission } : reply;
}
