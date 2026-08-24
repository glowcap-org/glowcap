import type { Behavior } from "./value.ts";

/** One hosted object's behavior and Host-local reference resolver. */
export interface BehaviorEntry {
	run: Behavior;
	/** Resolve a local Host capability id to its entry, or null before the entry
	 * joins the Host's local-composition index. */
	resolveLocal: ((refId: bigint) => BehaviorEntry | undefined) | null;
}

// A live Host strongly owns its entries; the process-wide index stays weak so
// behavior closures cannot turn Host-local cycles into global roots.
const registry = new Map<bigint, WeakRef<BehaviorEntry>>();
const nativeOwners = new Map<bigint, WeakRef<NativeBehaviorOwner>>();
let nextId = 1n;

/** Owner notified when a native hosted actor drops its last root. */
export interface NativeBehaviorOwner {
	nativeBehaviorReleased(id: bigint): void;
}

/** Register a hosted object's behavior, returning its pointer-sized ctx id. */
export function registerBehavior(entry: BehaviorEntry, nativeOwner?: NativeBehaviorOwner): bigint {
	const id = nextId++;
	registry.set(id, new WeakRef(entry));
	if (nativeOwner !== undefined) nativeOwners.set(id, new WeakRef(nativeOwner));
	return id;
}

/** Drop a hosted entry after its Host is released. Binding-internal. */
export function unregisterBehavior(id: bigint): void {
	nativeOwners.delete(id);
	registry.delete(id);
}

/** The entry behind a ctx id, for in-process `Forward` composition. */
export function entryFor(id: bigint): BehaviorEntry | undefined {
	const entry = registry.get(id)?.deref();
	if (entry === undefined) registry.delete(id);
	return entry;
}

/** Retire a natively owned publication at its last-root notification. */
export function releaseNativeBehavior(id: bigint): void {
	nativeOwners.get(id)?.deref()?.nativeBehaviorReleased(id);
	unregisterBehavior(id);
}
