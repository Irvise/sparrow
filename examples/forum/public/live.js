// Tells the reader when someone posts: the server sends a "thread" or "reply" event with the thread's id.
// A thread page cares about replies to it; the thread list about everything.
//
// Over HTTP/1.1 a browser opens at most six connections to a server, and each open stream holds one. So the
// stream is closed whenever the page is left (also when the browser keeps it in its back/forward cache) and
// opened again when it comes back; otherwise a few tabs and back-button visits use them all up, and the next
// page waits until one is let go.
const watched = document.querySelector("[data-watch]");
if (watched && window.EventSource) {
  const scope = watched.dataset.watch;
  const banner = document.getElementById("live");
  let events = null;
  const notice = (event) => {
    if (scope === "all" || (event.type === "reply" && event.data === scope)) banner.hidden = false;
  };
  const open = () => {
    if (events) return;
    events = new EventSource("/events");
    events.addEventListener("thread", notice);
    events.addEventListener("reply", notice);
  };
  const close = () => {
    if (events) events.close();
    events = null;
  };
  addEventListener("pagehide", close);
  addEventListener("pageshow", open);
  // A hidden tab lets its stream go too; what was posted meanwhile shows on the next load.
  document.addEventListener("visibilitychange", () => (document.hidden ? close() : open()));
  if (!document.hidden) open();
  banner.querySelector("a").addEventListener("click", (event) => {
    event.preventDefault();
    location.reload();
  });
}
