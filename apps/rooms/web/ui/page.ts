import type { ManagedRoomsSession } from "./session/managed/session.ts";
// One page owns presentation and handles to the Rust application. Connections,
// members, recordings and protocol capabilities belong to that application.
import { PageBootstrap } from "./page_bootstrap.ts";
import { PageTyping } from "./typing.ts";
import { ControllerSelection } from "./controller/selection.ts";
import { PageProjection } from "./store/core.ts";

export interface RoomsPageContext {
	readonly bootstrap: PageBootstrap;
	readonly typing: PageTyping;
	readonly controllerSelection: ControllerSelection;
	readonly projection: PageProjection;
	managedSession: ManagedRoomsSession | null;
}
export class RoomsPage implements RoomsPageContext {
	readonly bootstrap = new PageBootstrap();
	readonly typing = new PageTyping();
	readonly controllerSelection = new ControllerSelection();
	readonly projection = new PageProjection();
	managedSession: ManagedRoomsSession | null = null;
}
