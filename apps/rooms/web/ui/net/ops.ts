// The lifecycle of an operations capability: take it, drop it, ask it again.
//
// The saved bundle is the acquisition surface. This table keeps its
// reconciliation from becoming one switch per capability for take, drop, and
// refresh; `ops/catalog.ts` owns the matching presentation vocabulary.
//
// The visualizer and peering have no refresh because they have nothing to
// ask: the viz pane draws this tab's own publishing socket and the peering
// pane draws this tab's own publications, both of which the store already
// knows about.

import type { OpsCap } from "../types.ts";
import { opsHeldOf } from "../types.ts";
import * as store from "../store.ts";
import { formatOpsBundle, OPS_BUNDLE_CAPABILITIES, opsBundleReady, parseOpsBundleDraft } from "../ops/bundle.ts";
import { onOperationsInvalidated } from "../ops/invalidation.ts";
import { broadcastCapabilitySetChanged } from "../ops/capability_set_events.ts";
import { dropDiagnosticCap, refreshDiagnostics, takeDiagnosticCap } from "./diagnostics.ts";
import { dropIrcGatewayCap, refreshIrcGateway, takeIrcGatewayCap } from "./irc.ts";
import { dropListenersCap, refreshListeners, takeListenersCap } from "./listeners.ts";
import { dropOperatorCap, refreshOperator, takeOperatorCap } from "./operator.ts";
import { dropPeeringCap, takePeeringCap } from "./peering.ts";
import { dropVizCap, takeVizCap, vizCapabilityScope } from "./viz.ts";
import { rememberedOpsCredentials, replaceOpsCredentials } from "./ops_memory.ts";

interface OpsVerbs {
	/** Redeem `pasted` for this capability, empty when the tab now holds it
	 * and the reason it would not take otherwise. `remember` is the reader's
	 * current word on keeping the swiss in this browser. */
	readonly take: (pasted: string, remember?: boolean) => Promise<string>;
	/** Let it go, swiss and all. */
	readonly drop: (updateVault?: boolean) => void | Promise<void>;
	/** Ask the capability in hand to say again what it holds, where there is
	 * something to ask. */
	readonly refresh?: () => Promise<void>;
}

const VERBS: Record<OpsCap, OpsVerbs> = {
	listeners: { take: takeListenersCap, drop: dropListenersCap, refresh: refreshListeners },
	diagnostics: { take: takeDiagnosticCap, drop: dropDiagnosticCap, refresh: refreshDiagnostics },
	irc: { take: takeIrcGatewayCap, drop: dropIrcGatewayCap, refresh: refreshIrcGateway },
	operator: { take: takeOperatorCap, drop: dropOperatorCap, refresh: refreshOperator },
	peering: { take: takePeeringCap, drop: dropPeeringCap },
	viz: { take: takeVizCap, drop: dropVizCap },
};

onOperationsInvalidated(async () => {
	await Promise.all(Object.values(VERBS).map((verbs) => verbs.refresh?.()));
});

function takeOpsCap(cap: OpsCap, pasted: string, remember = false): Promise<string> {
	return VERBS[cap].take(pasted, remember);
}

async function savedOpsBundle(): Promise<Map<OpsCap, string>> {
	const home = store.get().homeDir;
	const vizScope = await vizCapabilityScope();
	const bundle = new Map<OpsCap, string>();
	for (const credential of rememberedOpsCredentials()) {
		const inScope = credential.capability === "viz"
			? vizScope != null && credential.scope === vizScope
			: home != null && credential.scope === home;
		if (inScope) bundle.set(credential.capability, credential.swiss);
	}
	return bundle;
}

export async function readOpsBundle(): Promise<string> {
	return formatOpsBundle(await savedOpsBundle());
}

export interface OpsBundleResult {
	readonly bundle: string;
	readonly failures: readonly { capability: OpsCap | null; reason: string }[];
}

function explainRefusal(capability: OpsCap, reason: string): string {
	if (reason.toLowerCase().includes("unknown swissnum")) {
		const token = OPS_BUNDLE_CAPABILITIES.find((entry) => entry.capability === capability)?.token ?? "ROOMS-*";
		return `This server does not recognize that swiss number. It may belong to another directory or an earlier ` +
			`server capability set. Paste the current ${token} value printed by this server.`;
	}
	return reason;
}

/** Reconcile the one saved capability set with live possession. Every
 * accepted entry is remembered; every removed entry is released and erased.
 * Refusals are isolated, and the returned bundle is the authority that
 * actually committed rather than the draft that was requested. */
export async function replaceOpsBundle(raw: string): Promise<OpsBundleResult> {
	let wanted: Map<OpsCap, string>;
	try {
		wanted = new Map(parseOpsBundleDraft(raw));
		if (wanted.size > 0 && !opsBundleReady(wanted)) {
			throw new Error("Supply a swiss number for every enabled capability.");
		}
	} catch (error) {
		return {
			bundle: await readOpsBundle(),
			failures: [{ capability: null, reason: error instanceof Error ? error.message : String(error) }],
		};
	}
	const before = await savedOpsBundle();
	const home = store.get().homeDir;
	const vizScope = await vizCapabilityScope();
	const scopedFailures: { capability: OpsCap; reason: string }[] = [];
	const nextCredentials = rememberedOpsCredentials().filter((credential) =>
		credential.capability !== "viz" && (home == null || credential.scope !== home)
	);
	for (const [capability, swiss] of wanted) {
		const scope = capability === "viz" ? vizScope : home;
		if (scope == null) {
			scopedFailures.push({
				capability,
				reason: capability === "viz"
					? "This page has no live timeline endpoint to scope that capability to."
					: "This directory is not connected yet, so the capability has no authority scope.",
			});
			continue;
		}
		nextCredentials.push({ capability, scope, swiss });
	}
	if (scopedFailures.length > 0) return { bundle: formatOpsBundle(before), failures: scopedFailures };
	if (!replaceOpsCredentials(nextCredentials)) {
		return {
			bundle: formatOpsBundle(before),
			failures: [{
				capability: null,
				reason:
					"This browser could not replace the saved capability set. Browser storage may be unavailable or full.",
			}],
		};
	}
	const failures: { capability: OpsCap; reason: string }[] = [];
	for (const { capability } of OPS_BUNDLE_CAPABILITIES) {
		const desired = wanted.get(capability) ?? null;
		const current = before.get(capability) ?? null;
		let state = store.get();
		let held = opsHeldOf(state.listeners, state.diagnostics, state.irc, state.operator, state.peering, state.viz);
		if (desired === current && held[capability]) continue;
		if (held[capability]) {
			await dropOpsCap(capability, false);
			state = store.get();
			held = opsHeldOf(state.listeners, state.diagnostics, state.irc, state.operator, state.peering, state.viz);
			if (held[capability]) {
				failures.push({
					capability,
					reason: "The current capability could not be released, so its saved value remains.",
				});
				continue;
			}
		}
		if (desired == null) continue;
		const why = await takeOpsCap(capability, desired, true);
		if (why !== "") failures.push({ capability, reason: explainRefusal(capability, why) });
	}
	const bundle = await readOpsBundle();
	broadcastCapabilitySetChanged();
	return { bundle, failures };
}

async function dropOpsCap(cap: OpsCap, updateVault = true): Promise<void> {
	await VERBS[cap].drop(updateVault);
}

/** Ask `cap` again, or do nothing where it has nothing to ask. */
export async function refreshOpsCap(cap: OpsCap): Promise<void> {
	await VERBS[cap].refresh?.();
}
