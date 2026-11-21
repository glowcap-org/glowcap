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
		// Safari can blur the summary without focusing a tapped link. Keep it
		// visible until the click, unless focus has a known outside destination.
		if (event.relatedTarget instanceof Node && !appsMenu.contains(event.relatedTarget)) {
			appsMenu.open = false;
		}
	});
}
