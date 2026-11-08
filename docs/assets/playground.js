// The playground's scrub: a pair of buttons and the arrow keys move through the
// checkpoints a run wrote. Nothing here runs the engine; it reads records.

const clamp = (value, low, high) => Math.max(low, Math.min(high, value));

function move(step) {
  const engine = window.moonstate;
  if (!engine) return;
  const count = engine.count();
  if (count === 0) return;
  const now = engine.selected();
  const from = now === null ? count - 1 : now;
  engine.select(clamp(from + step, 0, count - 1));
}

for (const [id, step] of [["prev", -1], ["next", 1]]) {
  const button = document.getElementById(id);
  if (button) button.addEventListener("click", () => move(step));
}

addEventListener("keydown", (event) => {
  if (event.target instanceof HTMLInputElement) return;
  if (event.key === "ArrowLeft") {
    event.preventDefault();
    move(-1);
  }
  if (event.key === "ArrowRight") {
    event.preventDefault();
    move(1);
  }
});
