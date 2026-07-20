import { notifyToggle } from "./dom.ts";
import { LS, sysItem } from "./state.ts";
import { toActive } from "./render.ts";

// ── Desktop notifications when you are @mentioned or DMed (opt-in) ─────────
let notifyOn = LS.get("rooms.notify") === "1";
export function renderNotifyBtn() {
	notifyToggle.textContent = notifyOn ? "🔔" : "🔕";
	notifyToggle.classList.toggle("on", notifyOn);
	notifyToggle.setAttribute("aria-pressed", String(notifyOn));
}
notifyToggle.onclick = async () => {
	if (!notifyOn) {
		if (!("Notification" in window)) {
			toActive(sysItem("This browser can't show desktop notifications"));
			return;
		}
		let perm = Notification.permission;
		if (perm === "default") perm = await Notification.requestPermission();
		if (perm !== "granted") {
			toActive(
				sysItem("Notifications are blocked in your browser settings"),
			);
			return;
		}
		notifyOn = true;
	} else notifyOn = false;
	LS.set("rooms.notify", notifyOn ? "1" : "0");
	renderNotifyBtn();
};
export function maybeNotify(title: string, text: string) {
	if (!notifyOn || !document.hidden) return;
	if (!("Notification" in window) || Notification.permission !== "granted") {
		return;
	}
	try {
		new Notification(title, { body: text.slice(0, 140) });
	} catch {
		/* notification construction can throw on some platforms; ignore */
	}
}
