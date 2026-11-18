// A static script, to show JavaScript served with its media type.
const clock = document.getElementById("clock");
const tick = () => { clock.textContent = "Loaded " + new Date().toLocaleTimeString() + "."; };
tick();
