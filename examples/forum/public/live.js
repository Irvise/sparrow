// Tells the reader when someone posts: the server sends a "thread" or "reply" event with the thread's id.
// A thread page cares about replies to it; the thread list about everything.
const watched = document.querySelector("[data-watch]");
if (watched && window.EventSource) {
  const scope = watched.dataset.watch;
  const banner = document.getElementById("live");
  const events = new EventSource("/events");
  const notice = (event) => {
    if (scope === "all" || (event.type === "reply" && event.data === scope)) banner.hidden = false;
  };
  events.addEventListener("thread", notice);
  events.addEventListener("reply", notice);
  banner.querySelector("a").addEventListener("click", (event) => {
    event.preventDefault();
    location.reload();
  });
}
