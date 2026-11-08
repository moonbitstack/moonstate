// The two things the reading pages need: a filter over the reference, and a rail
// that says where you are in the guide. Both work without the script; the rail is
// simply a list of links and the reference is simply long.

const $ = (id) => document.getElementById(id);

/* ---------- the reference ---------- */

function wireFilter() {
  const input = $("filter");
  const entries = [...document.querySelectorAll(".entries article")];
  if (!input || entries.length === 0) return;
  const count = $("filter-count");
  const total = entries.length;
  const members = new Map(entries.map((entry) => [entry, [...entry.querySelectorAll(".member")]]));
  const memberTotal = document.querySelectorAll(".entries .member").length;
  const all = `${total} items · ${memberTotal} members`;

  const apply = () => {
    const terms = input.value.toLowerCase().split(/\s+/).filter(Boolean);
    let shown = 0;
    for (const entry of entries) {
      const own = (entry.querySelector("h3")?.textContent || "") + " " + (entry.querySelector("p")?.textContent || "");
      const body = entry.textContent.toLowerCase();
      const membersOf = members.get(entry);
      if (terms.length === 0 || terms.every((term) => body.includes(term))) {
        entry.hidden = false;
        for (const member of membersOf) member.hidden = false;
        shown += 1;
        continue;
      }
      let matched = terms.every((term) => own.toLowerCase().includes(term));
      for (const member of membersOf) {
        const hit = terms.every((term) => member.textContent.toLowerCase().includes(term));
        member.hidden = !hit;
        matched = matched || hit;
      }
      entry.hidden = !matched;
      if (matched) shown += 1;
    }
    for (const section of document.querySelectorAll(".entries section")) {
      section.hidden = [...section.querySelectorAll("article")].every((article) => article.hidden);
    }
    for (const link of document.querySelectorAll(".rail a")) {
      const target = document.querySelector(link.getAttribute("href"));
      link.hidden = Boolean(target && target.hidden);
    }
    if (count) {
      count.textContent = terms.length ? `${shown} of ${total} items` : all;
    }
  };

  input.addEventListener("input", apply);
  input.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      input.value = "";
      apply();
      input.blur();
    }
  });
  addEventListener("keydown", (event) => {
    if (event.key === "/" && document.activeElement !== input && !event.metaKey && !event.ctrlKey) {
      event.preventDefault();
      input.focus();
    }
  });
  if (count) count.textContent = all;
}

/* ---------- the guide ---------- */

function wireRail() {
  const links = [...document.querySelectorAll(".rail a[href^='#']")];
  if (links.length === 0) return;
  const sections = links
    .map((link) => document.querySelector(link.getAttribute("href")))
    .filter(Boolean);
  if (sections.length === 0) return;

  const current = () => {
    let best = sections[0];
    for (const section of sections) {
      if (section.getBoundingClientRect().top <= 120) best = section;
    }
    return best;
  };

  const paint = () => {
    const now = current();
    for (const link of links) {
      link.classList.toggle("is-current", link.getAttribute("href") === `#${now.id}`);
    }
  };

  addEventListener("scroll", paint, { passive: true });
  paint();

  // A heading is a link to itself, which is what a reader wants to copy.
  for (const heading of document.querySelectorAll(".prose h2[id]")) {
    heading.insertAdjacentHTML(
      "beforeend",
      `<a class="anchor" href="#${heading.id}" aria-label="Link to this section">#</a>`,
    );
  }
}

wireFilter();
wireRail();
