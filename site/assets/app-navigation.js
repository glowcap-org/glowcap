// Native disclosure keeps the app links available without JavaScript.
const appsMenu = document.getElementById("appsMenu");
if (appsMenu instanceof HTMLDetailsElement) {
	document.addEventListener("click", (event) => {
		if (event.target instanceof Node && !appsMenu.contains(event.target)) {
			appsMenu.open = false;
		}
	});
	appsMenu.addEventListener("keydown", (event) => {
		if (event.key === "Escape" && appsMenu.open) {
			appsMenu.open = false;
			appsMenu.querySelector("summary").focus();
		}
	});
	appsMenu.addEventListener("focusout", (event) => {
		if (!(event.relatedTarget instanceof Node) || !appsMenu.contains(event.relatedTarget)) {
			appsMenu.open = false;
		}
	});
}
