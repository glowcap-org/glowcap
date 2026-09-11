// One page owns presentation and handles to the Rust application. Connections,
// members, recordings and protocol capabilities belong to that application.
import { PageBootstrap } from "./page_bootstrap.ts";
import { PageTyping } from "./typing.ts";
import { PageAttachedSession } from "./session/attached_hold.ts";
import { PageHostedSession } from "./session/hosted_hold.ts";
import { PageProjection } from "./store/core.ts";
import { PageWorkspace } from "./workspace_state.ts";
import type { RoomsBrowserArchive } from "../../../../zig-out/wasm/rooms/rooms_browser.js";

export interface RoomsPageContext {
	readonly bootstrap: PageBootstrap;
	readonly typing: PageTyping;
	readonly workspace: PageWorkspace;
	readonly attachedSession: PageAttachedSession;
	readonly hostedSession: PageHostedSession;
	readonly projection: PageProjection;
	browserArchive: RoomsBrowserArchive | null;
}
export class RoomsPage implements RoomsPageContext {
	readonly bootstrap = new PageBootstrap();
	readonly typing = new PageTyping();
	readonly workspace = new PageWorkspace();
	readonly attachedSession = new PageAttachedSession();
	readonly hostedSession = new PageHostedSession();
	readonly projection = new PageProjection();
	browserArchive: RoomsBrowserArchive | null = null;
}
