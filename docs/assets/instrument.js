// The page's half of the demonstration. Every number it draws came back from
// `../engine/moonstate.js`, which is this library compiled to JavaScript; nothing
// here invents a state, a checkpoint or a superstep count.
//
// The demo is a script of five stages, and each stage is a few real calls into
// the engine: a fresh saver, a run, an answer. Jumping to a stage replays the
// ones before it, so what a visitor sees at stage four is the state a person
// would have reached by pressing the buttons themselves.

import { reset, run, answer, rewrite, dump, restore } from "../engine/moonstate.js";

const CENTRE = 260;
const RADIUS = 200;
const STORE = "moonstate.run.v1";
const SEEN = "moonstate.stages.v1";
const BEAT = 1700;

const STAGES = [
  {
    name: "a line",
    scenario: "line",
    actions: ["run"],
    caption: "a line — seed, double, stamp: three supersteps and four checkpoints.",
  },
  {
    name: "a question",
    scenario: "review",
    actions: ["run"],
    caption: "a question — the second node asks, and the run stops with the question in a checkpoint.",
  },
  {
    name: "the answer",
    scenario: "review",
    actions: ["run", "answer:7"],
    caption: "the answer — 7 goes back into the same thread, and the node that asked reads it.",
  },
  {
    name: "a fan-out",
    scenario: "fanout",
    actions: ["run"],
    caption: "a fan-out — one superstep, three shards, one fold in the order they were queued.",
  },
  {
    name: "a rewrite",
    scenario: "line",
    actions: ["run", "rewrite"],
    caption:
      "a rewrite — update starts a new branch from double, so the dial counts it from 0; the six checkpoints of both branches stay.",
  },
  {
    name: "the plug",
    scenario: "line",
    actions: ["run", "plug"],
    caption:
      "the plug — the tab reloads under the run. It comes back where it was, because a checkpoint is a record.",
    after:
      "the plug — the tab reloaded, and the run is still here: three supersteps, four checkpoints, none of them re-run.",
  },
];

const $ = (id) => document.getElementById(id);
const tickLayer = $("ticks");
const notchLayer = $("notches");
const capLayer = $("cap");
const arc = $("arc");
const ledger = $("ledger");
const svgNS = "http://www.w3.org/2000/svg";

let payload = null;
let limit = 25;
let picked = null;
let seen = new Set(loadSeen());
let stageNow = null;
let playing = false;
let token = 0;

const at = (index) => ((-90 + (index * 360) / limit) * Math.PI) / 180;

const point = (index, radius) => [
  CENTRE + radius * Math.cos(at(index)),
  CENTRE + radius * Math.sin(at(index)),
];

const round = (value) => Math.round(value * 10) / 10;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function loadSeen() {
  try {
    const raw = JSON.parse(sessionStorage.getItem(SEEN) || "[]");
    return Array.isArray(raw) ? raw : [];
  } catch {
    return [];
  }
}

function saveSeen() {
  try {
    sessionStorage.setItem(SEEN, JSON.stringify([...seen]));
  } catch {
    // A tab that refuses storage forgets which stages were shown; nothing breaks.
  }
}

function buildRing() {
  tickLayer.replaceChildren();
  notchLayer.replaceChildren();

  for (let i = 0; i < limit; i += 1) {
    const [x1, y1] = point(i, RADIUS - 6);
    const [x2, y2] = point(i, RADIUS + (i % 5 === 0 ? 11 : 7));
    const line = document.createElementNS(svgNS, "line");
    line.setAttribute("x1", round(x1));
    line.setAttribute("y1", round(y1));
    line.setAttribute("x2", round(x2));
    line.setAttribute("y2", round(y2));
    line.setAttribute("class", "tick");
    line.dataset.index = String(i);
    tickLayer.append(line);

    if (i > 0 && i % 5 === 0) {
      const [nx, ny] = point(i, RADIUS + 26);
      const numeral = document.createElementNS(svgNS, "text");
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

  // Where the run stopped because it ran out of graph, rather than because it ran
  // out of something to say: a short radial mark outside the rim.
  if (capLayer) {
    capLayer.replaceChildren();
    if (payload && payload.outcome === "done" && phase > 0) {
      const [x1, y1] = point(phase, RADIUS + 13);
      const [x2, y2] = point(phase, RADIUS + 21);
      const mark = document.createElementNS(svgNS, "line");
      mark.setAttribute("x1", round(x1));
      mark.setAttribute("y1", round(y1));
      mark.setAttribute("x2", round(x2));
      mark.setAttribute("y2", round(y2));
      mark.setAttribute("class", "cap");
      mark.setAttribute("stroke-linecap", "round");
      capLayer.append(mark);
    }
  }

  notchLayer.replaceChildren();
  checkpoints.forEach((checkpoint, index) => {
    const [x, y] = point(checkpoint.step, RADIUS);
    const notch = document.createElementNS(svgNS, "circle");
    notch.setAttribute("cx", round(x));
    notch.setAttribute("cy", round(y));
    notch.setAttribute("r", "3.4");
    notch.setAttribute("class", "notch");
    notch.setAttribute("tabindex", "0");
    notch.setAttribute("role", "button");
    notch.setAttribute(
      "aria-label",
      `checkpoint ${checkpoint.id}, superstep ${checkpoint.step}`,
    );
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
  return `n = ${state.n} · log = [${log}]`;
};

function verdictText() {
  if (!payload) return "loading the engine";
  if (picked !== null && payload.checkpoints[picked]) {
    return `reading ${payload.checkpoints[picked].id}`;
  }
  switch (payload.outcome) {
    case "empty":
      return "a fresh thread, no checkpoints";
    case "asking": {
      const asked =
        payload.asking && payload.asking.ask ? `“${payload.asking.ask}”` : "an answer";
      return `stopped at a question: ${asked}`;
    }
    case "done":
      return `the graph ended · ${payload.checkpoints.length} checkpoints`;
    case "failed":
      return `stopped: ${payload.reason || "a node failed"}`;
    case "restored":
      return "carried on from this browser's records";
    default:
      return payload.outcome;
  }
}

const HINTS = {
  line: {
    idle: "three nodes in a row: seed → double → stamp.",
    done: "read a checkpoint below, or press Rewrite the tail to take the run back.",
  },
  review: {
    idle: "the second node asks a question, and the run stops until you answer.",
    asking: "press Answer: the node that asked runs again and reads what you typed.",
    done: "the answer was written to the checkpoint before the node read it.",
  },
  fanout: {
    idle: "one superstep, three shards; their writes fold in the order they were queued.",
    done: "n = 3 because the merge adds — a replacing merge would keep only the last shard.",
  },
};

function hintText() {
  if (!payload) return "";
  const set = HINTS[payload.scenario] || HINTS.line;
  if (payload.outcome === "asking") return set.asking || set.idle;
  if (payload.outcome === "done") return set.done || set.idle;
  return set.idle;
}

/* ---------- the demo track ---------- */

function renderStages() {
  const track = $("stages");
  if (!track) return;
  const next = STAGES.findIndex((_, index) => !seen.has(index));

  for (const item of track.querySelectorAll("li")) {
    const index = Number(item.querySelector("button").dataset.stage);
    item.classList.toggle("is-now", stageNow === index);
    item.classList.toggle("is-done", seen.has(index) && stageNow !== index);
    item.classList.toggle("is-next", next === index && stageNow !== index);
  }

  if ($("stage-note")) {
    const stage = stageNow !== null ? STAGES[stageNow] : null;
    const after = payload && payload.outcome === "restored" && stage && stage.after;
    $("stage-note").textContent = stage
      ? `${stageNow + 1} · ${after || stage.caption}`
      : "press play, or pick a stage: each one runs the engine to that point.";
  }

  if ($("play")) {
    $("play").classList.toggle("is-playing", playing);
    const label = $("play").querySelector(".demo-label");
    if (label) label.textContent = playing ? "stop the demo" : "play the demo";
    $("play").setAttribute("aria-pressed", playing ? "true" : "false");
  }
}

async function gotoStage(index) {
  const wanted = Math.max(0, Math.min(STAGES.length - 1, index));
  for (let i = 0; i <= wanted; i += 1) {
    const stage = STAGES[i];
    await apply(reset(stage.scenario), true);
    for (const action of stage.actions) {
      if (action === "run") await apply(run(), true);
      else if (action === "rewrite") await apply(rewrite("double"), true);
      else if (action === "plug") {
        stageNow = i;
        await persist(true);
        location.reload();
        return;
      } else if (action.startsWith("answer:")) {
        await apply(answer(action.slice("answer:".length)), true);
      }
    }
  }
  stageNow = wanted;
  seen.add(wanted);
  saveSeen();
  await persist();
  render();
}

async function playDemo() {
  if (playing) {
    playing = false;
    token += 1;
    renderStages();
    return;
  }
  playing = true;
  const mine = ++token;
  renderStages();
  for (let i = 0; i < STAGES.length; i += 1) {
    if (!playing || mine !== token) return;
    await gotoStage(i);
    if (i < STAGES.length - 1) await sleep(BEAT);
  }
  playing = false;
  renderStages();
}

/* ---------- rendering ---------- */

function render() {
  if (!payload) return;
  limit = payload.limit || 25;
  const record = picked !== null ? payload.checkpoints[picked] : null;
  const state = record ? record.state : payload.state;

  if ($("limit")) $("limit").textContent = String(limit);
  $("phase").textContent = String(payload.phase);
  $("verdict").textContent = verdictText();
  if ($("hint")) $("hint").textContent = hintText();
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

  if (ledger) {
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
  }

  const asking = payload.outcome === "asking";
  if ($("answer-row")) $("answer-row").hidden = !asking;
  if ($("run")) $("run").disabled = asking;
  if ($("rewrite")) {
    $("rewrite").hidden = !(payload.outcome === "done" && payload.scenario === "line");
  }
  for (const chip of document.querySelectorAll(".chip")) {
    chip.classList.toggle("is-on", chip.dataset.scenario === payload.scenario);
  }

  renderStages();
  drawRing();
  showRecord(record || payload.checkpoints[payload.checkpoints.length - 1] || null);
}

// The record itself, on the page that shows it: the JSON a Saver hands back.
function showRecord(record) {
  const panel = $("record");
  if (!panel) return;
  panel.innerHTML = record ? highlight(JSON.stringify(record, null, 2)) : "{ }";
}

const TOKEN =
  /("(?:\\u[a-fA-F0-9]{4}|\\[^u]|[^\\"])*")(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?/g;

function highlight(text) {
  const escaped = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return escaped.replace(TOKEN, (match, string, colon, literal) => {
    if (string) {
      return colon
        ? `<span class="j-key">${string}</span>${colon}`
        : `<span class="j-str">${string}</span>`;
    }
    if (literal) return `<span class="j-bool">${literal}</span>`;
    return `<span class="j-num">${match}</span>`;
  });
}

function pick(index) {
  picked = picked === index ? null : index;
  render();
}

async function persist(pending = false) {
  try {
    const records = await dump();
    localStorage.setItem(
      STORE,
      JSON.stringify({ scenario: payload.scenario, records, plug: pending, stage: stageNow }),
    );
  } catch {
    localStorage.removeItem(STORE);
  }
}

async function apply(call, quiet = false) {
  const text = await call;
  payload = JSON.parse(text);
  if (payload.status === "failed" && !payload.outcome) payload.outcome = "failed";
  picked = null;
  if (!quiet) {
    await persist();
    render();
  }
}

async function boot() {
  buildRing();
  try {
    const saved = localStorage.getItem(STORE);
    if (saved) {
      const { scenario, records, plug, stage } = JSON.parse(saved);
      const list = JSON.parse(records);
      if (Array.isArray(list) && list.length > 0) {
        await apply(restore(scenario, records));
        if (plug && typeof stage === "number") {
          stageNow = stage;
          seen.add(stage);
          saveSeen();
        }
        renderStages();
        return;
      }
    }
  } catch {
    localStorage.removeItem(STORE);
  }
  await apply(reset("line"));
  await apply(run());
}

$("run").addEventListener("click", () => {
  stageNow = null;
  renderStages();
  apply(run());
});

$("reset").addEventListener("click", () => {
  const scenario = payload ? payload.scenario : "line";
  localStorage.removeItem(STORE);
  stageNow = null;
  renderStages();
  apply(reset(scenario));
});

for (const chip of document.querySelectorAll(".chip")) {
  chip.addEventListener("click", () => {
    localStorage.removeItem(STORE);
    stageNow = null;
    renderStages();
    apply(reset(chip.dataset.scenario));
  });
}

$("controls").addEventListener("submit", (event) => {
  event.preventDefault();
  const value = $("answer").value.trim() || "7";
  stageNow = null;
  renderStages();
  apply(answer(value));
});

$("rewrite").addEventListener("click", () => {
  stageNow = null;
  renderStages();
  apply(rewrite("double"));
});

if ($("pull")) {
  $("pull").addEventListener("click", async () => {
    await persist(true);
    location.reload();
  });
}

if ($("play")) {
  $("play").addEventListener("click", () => playDemo());
}

for (const button of document.querySelectorAll("[data-stage]")) {
  button.addEventListener("click", () => {
    token += 1;
    playing = false;
    gotoStage(Number(button.dataset.stage));
  });
}

window.moonstate = {
  count: () => (payload ? payload.checkpoints.length : 0),
  selected: () => picked,
  payload: () => payload,
  select: (index) => {
    picked = index;
    render();
  },
};

boot().catch((error) => {
  const verdict = document.getElementById("verdict");
  if (verdict) verdict.textContent = `the engine did not load: ${error.message}`;
});
