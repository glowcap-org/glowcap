// Assemble a durable Rooms session onto a running CapTP Host.
//
// The process host (listen, identity seed, admin mirror) stays outside. This
// owns the order that must not drift: grant callbacks close over behavior
// before it exists, the root is published, grants restore, then checkpoint
// changes reconcile without blocking attach.

import type { Host } from "@pancake/runtime";
import { formatRoomsSturdyref, roomsLocator } from "../lib/locator.ts";
import { DurableRoomsSessionBehavior } from "./behavior.ts";
import type { DurableRoomsSessionGrants } from "./grants.ts";
import { DurableRoomsRuntime } from "./runtime.ts";
import { DurableRoomsSessionState } from "./state.ts";

export interface BindDurableRoomsSession {
	readonly host: Host;
	readonly advertisedLocator: string;
	readonly state: DurableRoomsSessionState;
	readonly live: DurableRoomsRuntime;
	readonly onReconciliationFailure: (error: unknown) => void;
}

export interface BoundDurableRoomsSession {
	readonly grants: DurableRoomsSessionGrants;
	readonly behavior: DurableRoomsSessionBehavior;
	readonly sturdyref: string;
	/** Stop checkpoint reconciliation and unpublish the administrator root.
	 * Grant facets stay until their own revoke; the Host going away takes them. */
	release(): void;
}

export async function bindDurableRoomsSession(
	options: BindDurableRoomsSession,
): Promise<BoundDurableRoomsSession> {
	const { host, advertisedLocator, state, live, onReconciliationFailure } = options;
	// Opening loads the grant ledger but publishes nothing. These callbacks
	// first run from restore or issue, after the behavior binding below exists.
	const grants = await state.openGrants({
		publish: (grant, entropy, active) =>
			host.publishDurable(behavior.durableFacet(grant.rights, grant.id, active), entropy),
		unpublish: (swiss) => host.unpublishDurable(swiss),
		sturdyref: (_session, swiss) => formatRoomsSturdyref(roomsLocator(advertisedLocator), swiss),
		revokeLive: (id) => behavior.revokeDurableFacet(id),
	});
	const behavior = new DurableRoomsSessionBehavior(state, live, grants);
	const swiss = host.publishDurable(behavior.root(), state.sessionEntropy);
	try {
		live.setMemberLocator(advertisedLocator);
		const sturdyref = formatRoomsSturdyref(roomsLocator(advertisedLocator), swiss);
		await grants.restore();
		const stopReconcile = state.onCheckpointChange((_revision, checkpoint, impact) => {
			void live.reconcile(checkpoint, impact).catch(onReconciliationFailure);
		});
		// Durable state and the published administrator capability are ready now.
		// Network realization is recoverable workspace state: schedule its first
		// bounded attempt, but do not make an unreachable saved directory prevent
		// the owner from attaching and seeing or repairing that state.
		void live.reconcile(state.snapshot().checkpoint).catch(onReconciliationFailure);
		return {
			grants,
			behavior,
			sturdyref,
			release() {
				stopReconcile();
				host.unpublishDurable(swiss);
			},
		};
	} catch (error) {
		host.unpublishDurable(swiss);
		throw error;
	}
}
