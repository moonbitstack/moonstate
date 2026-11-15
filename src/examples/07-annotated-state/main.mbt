///|
async fn main {
  let graph = @moonstate.Builder::new(merge=merge_counter, initial={
      n: 0,
      log: [],
      label: "",
    })
    .entry("seed")
    .node("seed", (_state, _run) => {
      [@moonstate.Write({ n: Some(1), log: Some(["seed"]), label: None, })]
    })
    .node("again", (_state, _run) => {
      [
        @moonstate.Write({
          n: Some(2),
          log: Some(["again"]),
          label: Some("done"),
        }),
      ]
    })
    .edge("seed", "again")
    .compile("annotated") catch {
      refused =>
        abort("the graph does not compile: " + (refused : Error).to_string())
    }
  let out = graph.run({ n: None, log: None, label: None, }) catch {
    error => abort("the run failed: " + (error : Error).to_string())
  }
  // `n` was added to, `log` appended to, `label` replaced.
  println("n = \{out.n}, log = \{out.log.join(", ")}, label = \{out.label}")
  if out.n != 3 || out.log != ["seed", "again"] || out.label != "done" {
    abort("the merge the annotation wrote is not the one the fields ask for")
  }
}
