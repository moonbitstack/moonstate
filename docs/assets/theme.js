// Light, dark, or whatever the system says.
//
// The first visit follows the system and keeps following it: a person who has
// never chosen gets the theme their machine asks for, and a change of that
// setting lands without a reload. The moment the toggle is used the choice is
// written down and the system stops speaking; every page reads the same key, so
// a choice made on the guide holds on the reference.
//
// This file is loaded synchronously in <head>: the attribute has to be on <html>
// before the first paint or the page flashes the other theme.
(() => {
  const KEY = "moonstate.theme";
  const root = document.documentElement;
  const query = matchMedia("(prefers-color-scheme: dark)");

  const stored = () => {
    try {
      const value = localStorage.getItem(KEY);
      return value === "light" || value === "dark" ? value : null;
    } catch {
      return null;
    }
  };

  const paint = (theme, source) => {
    root.dataset.theme = theme;
    root.dataset.themeSource = source;
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.content = theme === "dark" ? "#0e0e0c" : "#f2efe6";
    for (const button of document.querySelectorAll("[data-theme-toggle]")) {
      const target = theme === "dark" ? "light" : "dark";
      button.setAttribute("aria-label", `Switch to the ${target} theme`);
      button.setAttribute("title", `Switch to the ${target} theme`);
      button.dataset.themeShows = target;
    }
  };

  paint(stored() || (query.matches ? "dark" : "light"), stored() ? "chosen" : "system");

  query.addEventListener("change", (event) => {
    if (!stored()) paint(event.matches ? "dark" : "light", "system");
  });

  const toggle = () => {
    const next = root.dataset.theme === "dark" ? "light" : "dark";
    try {
      localStorage.setItem(KEY, next);
    } catch {
      // A browser that refuses storage still gets the theme for this page.
    }
    paint(next, "chosen");
  };

  const wire = () => {
    for (const button of document.querySelectorAll("[data-theme-toggle]")) {
      button.addEventListener("click", toggle);
    }
    // The button does not exist yet when this file runs in <head>, so the first
    // paint could not label it; do that now that the document is here.
    paint(root.dataset.theme, root.dataset.themeSource === "chosen" ? "chosen" : "system");
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", wire, { once: true });
  } else {
    wire();
  }

  // The keyboard shortcut a documentation reader expects, and the one thing the
  // rest of the site needs to know about this file.
  addEventListener("keydown", (event) => {
    if (event.key === "d" && (event.metaKey || event.ctrlKey) && event.shiftKey) {
      event.preventDefault();
      toggle();
    }
  });

  window.moonstateTheme = { toggle, current: () => root.dataset.theme };
})();
