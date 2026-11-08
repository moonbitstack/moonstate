// The page's half of the demonstration. Every number it draws came back from
// `../engine/moonstate.js`, which is this library compiled to JavaScript; nothing
// here invents a state, a checkpoint or a superstep count.

import { reset, run, answer, rewrite, dump, restore } from "../engine/moonstate.js";

const CENTRE = 260;
const RADIUS = 200;
const STORE = "moonstate.run.v1";
const MOVES = "moonstate.moves.v1";

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
let done = new Set(loadMoves());

const at = (index) => ((-90 + (index * 360) / limit) * Math.PI) / 180;

const point = (index, radius) => [
  CENTRE + radius * Math.cos(at(index)),
  CENTRE + radius * Math.sin(at(index)),
];

const round = (value) => Math.round(value * 10) / 10;

function loadMoves() {
  try {
    const raw = JSON.parse(sessionStorage.getItem(MOVES) || "[]");
    return Array.isArray(raw) ? raw : [];
  } catch {
    return [];
  }
}

function saveMoves() {
  try {
    sessionStorage.setItem(MOVES, JSON.stringify([...done]));
  } catch {
    // A tab that refuses storage simply forgets which moves were made.
  }
}

function mark(move) {
  if (done.has(move)) return;
  done.add(move);
  saveMoves();
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
  if (!capLayer) return;
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

function renderMoves() {
  if (document.querySelectorAll(".moves li").length === 0) return;
  const order = ["run", "ask", "plug"];
  const next = order.find((move) => !done.has(move)) || null;
  for (const item of document.querySelectorAll(".moves li")) {
    const move = item.dataset.move;
    item.classList.toggle("is-done", done.has(move));
    item.classList.toggle("is-next", move === next);
  }
}

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

  renderMoves();
  drawRing();
  showRecord(record || payload.checkpoints[payload.checkpoints.length - 1] || null);
}

// The record itself, on the page that shows it: the JSON a Saver hands back.
function showRecord(record) {
  const panel = $("record");
  if (!panel) return;
  panel.innerHTML = record ? highlight(JSON.stringify(record, null, 2)) : "{ }";
}

const TOKEN = /("(?:\\u[a-fA-F0-9]{4}|\\[^u]|[^\\"])*")(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?/g;

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
      JSON.stringify({ scenario: payload.scenario, records, plug: pending }),
    );
  } catch {
    localStorage.removeItem(STORE);
  }
}

async function apply(call) {
  const text = await call;
  payload = JSON.parse(text);
  if (payload.status === "failed" && !payload.outcome) payload.outcome = "failed";
  if (payload.outcome === "done" || payload.outcome === "asking") mark("run");
  if (payload.outcome === "asking") mark("ask");
  picked = null;
  await persist();
  render();
}

async function boot() {
  buildRing();
  try {
    const saved = localStorage.getItem(STORE);
    if (saved) {
      const { scenario, records, plug } = JSON.parse(saved);
      const list = JSON.parse(records);
      if (Array.isArray(list) && list.length > 0) {
        await apply(restore(scenario, records));
        if (plug) mark("plug");
        renderMoves();
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

async function switchTo(scenario) {
  localStorage.removeItem(STORE);
  await apply(reset(scenario));
  await apply(run());
}

for (const button of document.querySelectorAll("[data-do]")) {
  button.addEventListener("click", async () => {
    switch (button.dataset.do) {
      case "run":
        await switchTo("line");
        break;
      case "ask":
        await switchTo("review");
        break;
      case "plug":
        await persist(true);
        location.reload();
        break;
      default:
        break;
    }
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
