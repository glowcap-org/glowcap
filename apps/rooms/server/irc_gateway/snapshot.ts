// Exact operator projection of retained IRC networks and their channel leases.

import type { Argument } from "@pancake/runtime";
import type { OperatorIrcNetworks } from "./networks.ts";

export interface IrcBridgeSnapshotSource {
	readonly network: { readonly choice: { readonly network: string; readonly host: string; readonly port: number } };
	readonly channel: string;
	readonly roomName: string;
	readonly entryId: string;
	readonly status: "connecting" | "up" | "backoff";
	readonly problem: string;
}

export function projectIrcBridgeSnapshot(bridges: Iterable<IrcBridgeSnapshotSource>): Argument[] {
	return [...bridges].map((held) => [
		held.network.choice.network,
		held.channel,
		held.roomName,
		held.entryId,
		held.status,
		`${held.network.choice.host}:${held.network.choice.port}`,
		held.problem,
	]);
}

export function projectIrcGatewaySnapshot(
	networks: OperatorIrcNetworks,
	bridges: Iterable<IrcBridgeSnapshotSource>,
): Argument[] {
	return [networks.snapshot(), projectIrcBridgeSnapshot(bridges)];
}
