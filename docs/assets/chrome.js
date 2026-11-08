// The one piece of chrome every page carries: a way back to the top.
//
// It is added here rather than written into four pages, so the markup, the
// threshold and the focus behaviour cannot drift apart. It stays out of the tab
// order while it is invisible, which is the part a hand-written button usually
// gets wrong.

(() => {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "to-top";
  button.setAttribute("aria-label", "Back to the top");
  button.setAttribute("title", "Back to the top");
  button.setAttribute("aria-hidden", "true");
  button.tabIndex = -1;
  button.innerHTML =
    '<svg viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.4">' +
    '<path d="M8 13V3.5M4 7l4-4 4 4"></path></svg>';

  // The footer carries the last links on the page; the button steps aside rather
  // than sitting on top of them.
  let atFoot = false;

  const show = () => {
    const visible = window.scrollY > 900 && !atFoot;
    button.dataset.shown = visible ? "true" : "false";
    button.tabIndex = visible ? 0 : -1;
    button.setAttribute("aria-hidden", visible ? "false" : "true");
  };

  const foot = document.querySelector(".foot");
  if (foot && "IntersectionObserver" in window) {
    new IntersectionObserver(
      (entries) => {
        atFoot = entries[0].isIntersecting;
        show();
      },
      { rootMargin: "0px 0px -40px 0px" },
    ).observe(foot);
  }

  button.addEventListener("click", () => {
    const smooth = !matchMedia("(prefers-reduced-motion: reduce)").matches;
    window.scrollTo({ top: 0, behavior: smooth ? "smooth" : "auto" });
    // The button hides itself at the top, so hand focus to the wordmark rather
    // than leaving it on something invisible.
    const mark = document.querySelector(".mark");
    if (mark) mark.focus({ preventScroll: true });
  });

  document.body.append(button);
  addEventListener("scroll", show, { passive: true });
  show();
})();
