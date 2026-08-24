import React from "react";
import ReactDOM from "react-dom/client";
import "./styles.css";
import "./controls.css";
import { App } from "./App.tsx";
import { AppErrorBoundary } from "./ui/error/AppErrorBoundary.tsx";
import { pushError } from "./ui/error/error-bus.ts";
import { internalError } from "./engine/errors.ts";

// Safety-net handlers for errors that escape every more-specific
// channel: async Promise rejections (notably `app.init().then(...)`
// in `UnifiedCanvas`), uncaught synchronous errors in event listeners
// outside React's lifecycle (resize handlers, Pixi ticker callbacks
// before `safeTick` is in place). Install before `createRoot` so the
// listeners exist by the time the first effect runs.
globalThis.addEventListener("error", (ev) => {
	pushError({
		error: internalError(ev.error ?? ev.message),
		source: "window",
	});
});
globalThis.addEventListener("unhandledrejection", (ev) => {
	pushError({
		error: internalError(ev.reason),
		source: "unhandled-rejection",
	});
});

const rootElement = document.getElementById("root");
if (!rootElement) {
	throw new Error("ocapnviz: missing #root element in index.html");
}

ReactDOM.createRoot(rootElement).render(
	<React.StrictMode>
		<AppErrorBoundary>
			<App />
		</AppErrorBoundary>
	</React.StrictMode>,
);
