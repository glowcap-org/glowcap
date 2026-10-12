// Putting text on the clipboard from a rooms control.
//
// `navigator.clipboard` only writes in a secure context, and a hostname that is
// not localhost over HTTP is not one, `http://workstation.local:38080` is the
// shape a deployed rooms page has. Waiting for that API to refuse also
// spends the user gesture that `document.execCommand("copy")` needs, and under
// a modal dialog the document itself is inert, so a textarea appended to `body`
// cannot take the selection. The older write therefore runs first, from inside
// the control that was pressed, which is still live. The async API is the
// fallback for a browser that has disabled execCommand.

/** Write `text` to the clipboard. `from` is the control that asked, so the
 * selection is taken inside whatever layer still accepts input. */
export async function writeClipboard(text: string, from: ParentNode): Promise<void> {
	if (copyWithExecCommand(text, from)) return;
	const api = navigator.clipboard?.writeText?.bind(navigator.clipboard);
	if (api != null) {
		await api(text);
		return;
	}
	throw new Error("clipboard unavailable");
}

/** The live layer that still accepts a selection: a modal dialog if the control
 * is in one, otherwise the control itself. `document.body` is inert under a
 * native modal, which is why the write must not fall back to it. */
function liveRoot(from: ParentNode): ParentNode {
	if (!(from instanceof Element)) return from;
	return from.closest("dialog") ?? from;
}

/** The gesture-safe write. Returns whether the browser reported success. */
function copyWithExecCommand(text: string, from: ParentNode): boolean {
	const root = liveRoot(from);
	const prior = document.activeElement;
	const field = document.createElement("textarea");
	field.value = text;
	field.setAttribute("readonly", "");
	field.setAttribute("aria-hidden", "true");
	field.tabIndex = -1;
	field.style.cssText = "position:fixed;top:0;left:0;width:1px;height:1px;padding:0;border:0;opacity:0";
	root.appendChild(field);
	field.focus({ preventScroll: true });
	field.select();
	field.setSelectionRange(0, text.length);
	let ok = false;
	try {
		ok = document.execCommand("copy");
	} catch {
		ok = false;
	}
	field.remove();
	if (prior instanceof HTMLElement && prior !== field && document.contains(prior)) {
		prior.focus({ preventScroll: true });
	}
	return ok;
}
