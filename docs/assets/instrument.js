import { reset, run, answer, rewrite, dump, restore } from "../engine/moonstate.js";

const CENTRE = 260;
const RADIUS = 200;
const STORE = "moonstate.run.v1";

const $ = (id) => document.getElementById(id);
const ring = $("ring");
const tickLayer = $("ticks");
const notchLayer = $("notches");
const arc = $("arc");
const ledger = $("ledger");

let payload = null;
let limit = 25;
let picked = null;

const at = (index) =>
  ((-90 + (index * 360) / limit) * Math.PI) / 180;

const point = (index, radius) => [
  CENTRE + radius * Math.cos(at(index)),
  CENTRE + radius * Math.sin(at(index)),
];

const round = (value) => Math.round(value * 10) / 10;

function buildRing() {
  tickLayer.replaceChildren();
  notchLayer.replaceChildren();

  for (let i = 0; i < limit; i += 1) {
    const [x1, y1] = point(i, RADIUS - 7);
    const [x2, y2] = point(i, RADIUS + 9);
    const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
    line.setAttribute("x1", round(x1));
    line.setAttribute("y1", round(y1));
    line.setAttribute("x2", round(x2));
    line.setAttribute("y2", round(y2));
    line.setAttribute("class", "tick");
    line.dataset.index = String(i);
    tickLayer.append(line);

    if (i > 0 && i % 5 === 0) {
      const [nx, ny] = point(i, RADIUS + 26);
      const numeral = document.createElementNS("http://www.w3.org/2000/svg", "text");
      numeral.setAttribute("x", round(nx));
      numeral.setAttribute("y", round(ny + 4));
      numeral.setAttribute("text-anchor", "middle");
      numeral.setAttribute("class", "numeral");
      numeral.textContent = String(i);
      tickLayer.append(numeral);
    }
  }
}

function drawRing() {
  const phase = payload ? payload.phase : 0;
  const checkpoints = payload ? payload.checkpoints : [];

  for (const line of tickLayer.querySelectorAll(".tick")) {
    const index = Number(line.dataset.index);
    line.classList.toggle("is-run", index <= phase && phase > 0);
    line.classList.toggle("is-now", index === phase && phase > 0);
  }

  if (phase > 0) {
    const [x1, y1] = point(0, RADIUS);
    const [x2, y2] = point(phase, RADIUS);
    const sweep = phase * (360 / limit) > 180 ? 1 : 0;
    arc.setAttribute(
      "d",
      `M${round(x1)} ${round(y1)}A${RADIUS} ${RADIUS} 0 ${sweep} 1 ${round(x2)} ${round(y2)}`,
    );
  } else {
    arc.setAttribute("d", "");
  }

  notchLayer.replaceChildren();
  checkpoints.forEach((checkpoint, index) => {
    const [x, y] = point(checkpoint.step, RADIUS);
    const notch = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    notch.setAttribute("cx", round(x));
    notch.setAttribute("cy", round(y));
    notch.setAttribute("r", "3.4");
    notch.setAttribute("class", "notch");
    notch.setAttribute("tabindex", "0");
    notch.setAttribute("role", "button");
    notch.setAttribute("aria-label", `checkpoint ${checkpoint.id}, superstep ${checkpoint.step}`);
    notch.dataset.index = String(index);
    if (picked === index) notch.classList.add("is-picked");
    notch.addEventListener("click", () => pick(index));
    notch.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        pick(index);
      }
    });
    notchLayer.append(notch);
  });
}

const summary = (state) => {
  if (!state) return "{ }";
  const log = Array.isArray(state.log) ? state.log.join(", ") : "";
  return `n = ${state.n}   log = [${log}]`;
};

function verdictText() {
  if (!payload) return "loading the engine";
  if (picked !== null && payload.checkpoints[picked]) {
    return `reading ${payload.checkpoints[picked].id}`;
  }
  switch (payload.outcome) {
    case "empty":
      return "a fresh run, no checkpoints";
    case "asking": {
      const asked = payload.asking && payload.asking.ask ? `“${payload.asking.ask}”` : "an answer";
      return `stopped at a question: ${asked}`;
    }
    case "done":
      return `the graph reached its end, ${payload.checkpoints.length} checkpoints`;
    case "failed":
      return `stopped: ${payload.reason || "a node failed"}`;
    case "restored":
      return "picked up from the records in this browser";
    default:
      return payload.outcome;
  }
}

function render() {
  if (!payload) return;
  limit = payload.limit || 25;
  const record = picked !== null ? payload.checkpoints[picked] : null;
  const state = record ? record.state : payload.state;

  $("limit").textContent = String(limit);
  $("phase").textContent = String(payload.phase);
  $("verdict").textContent = verdictText();
  $("state").textContent = record ? summary(record.state) : summary(payload.state);
  $("state").dataset.empty = state ? "false" : "true";
  $("next-nodes").textContent = record
    ? record.next.length
      ? `next: ${record.next.join(", ")}`
      : "next: nothing, the run ended here"
    : payload.next.length
      ? `next: ${payload.next.join(", ")}`
      : "next: nothing";
  $("checkpoint").textContent = record
    ? `recorded ${record.id}`
    : payload.checkpoint || "no checkpoint";

  ledger.replaceChildren();
  payload.checkpoints.forEach((checkpoint, index) => {
    const row = document.createElement("li");
    row.tabIndex = 0;
    row.dataset.index = String(index);
    if (picked === index) row.classList.add("is-picked");
    row.innerHTML =
      `<span class="id">${checkpoint.id}</span>` +
      `<span class="what">${summary(checkpoint.state)} · ${
        checkpoint.next.length ? checkpoint.next.join(", ") : "end"
      }</span>` +
      `<span class="when">step ${checkpoint.step}${
        checkpoint.interrupted ? " · asks" : ""
      }</span>`;
    row.addEventListener("click", () => pick(index));
    row.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        pick(index);
      }
    });
    ledger.append(row);
  });

  const asking = payload.outcome === "asking";
  $("answer-row").hidden = !asking;
  $("run").disabled = asking;
  $("rewrite").hidden = !(payload.outcome === "done" && payload.scenario === "line");
  for (const chip of document.querySelectorAll(".chip")) {
    chip.classList.toggle("is-on", chip.dataset.scenario === payload.scenario);
  }

  drawRing();
}

function pick(index) {
  picked = picked === index ? null : index;
  render();
}

async function persist() {
  try {
    const records = await dump();
    localStorage.setItem(STORE, JSON.stringify({ scenario: payload.scenario, records }));
  } catch {
    localStorage.removeItem(STORE);
  }
}

async function apply(call) {
  const text = await call;
  payload = JSON.parse(text);
  if (payload.status === "failed" && !payload.outcome) payload.outcome = "failed";
  picked = null;
  await persist();
  render();
}

async function boot() {
  buildRing();
  const saved = localStorage.getItem(STORE);
  try {
    if (saved) {
      const { scenario, records } = JSON.parse(saved);
      const recordsList = JSON.parse(records);
      if (Array.isArray(recordsList) && recordsList.length > 0) {
        await apply(restore(scenario, records));
        return;
      }
    }
  } catch {
    localStorage.removeItem(STORE);
  }
  await apply(reset("line"));
  await apply(run());
}

$("run").addEventListener("click", () => apply(run()));

$("reset").addEventListener("click", () => {
  const scenario = payload ? payload.scenario : "line";
  localStorage.removeItem(STORE);
  apply(reset(scenario));
});

for (const chip of document.querySelectorAll(".chip")) {
  chip.addEventListener("click", () => {
    localStorage.removeItem(STORE);
    apply(reset(chip.dataset.scenario));
  });
}

$("controls").addEventListener("submit", (event) => {
  event.preventDefault();
  const value = $("answer").value.trim() || "7";
  apply(answer(value));
});

$("rewrite").addEventListener("click", () => apply(rewrite("double")));

$("pull").addEventListener("click", async () => {
  await persist();
  location.reload();
});

window.moonstate = {
  count: () => (payload ? payload.checkpoints.length : 0),
  selected: () => picked,
  select: (index) => {
    picked = index;
    render();
  },
};

boot().catch((error) => {
  const verdict = document.getElementById("verdict");
  if (verdict) verdict.textContent = `the engine did not load: ${error.message}`;
});
