// Public @pancake/iroh surface: hosting + posture. Dial goes through
// `@pancake/runtime`'s `connect(locator)`; the binding-internal dial lives at
// `@pancake/iroh/internal` and is not part of the application contract.
//
// Relay support: `dialLocatorForRelay` provides a byte-fed dial API for
// transparent relay implementations (e.g., browser peer → relay → native iroh).

export {
	connector,
	dialLocatorForRelay,
	type IrohConfig,
	IrohConnection,
	IrohNetlayer,
	IrohServer,
	listen,
	type ListenOptions,
	locator,
	provider,
	Reachability,
} from "./impl.ts";
