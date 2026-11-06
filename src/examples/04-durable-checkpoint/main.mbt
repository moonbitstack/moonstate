// Checkpoints on disk, and what they buy: kill the process halfway and start it
// again, and the run continues from the last superstep instead of starting over.
//
//   moon run src/examples/04-durable-checkpoint --target native -- <dir>
//
// The saver below is deliberately small — one file per checkpoint, one line per
// recorded task write — because `Saver` is a contract, not a database.

///|
#derive(@json.ToJson, @json.FromJson)
struct Job {
  step : Int32
  log : Array[String]
}

///|
pub extend Job with @json.ToJson::{to_json}

///|
pub extend Job with @json.FromJson::{from_json}

///|
#derive(@json.ToJson, @json.FromJson)
struct Done {
  step : Int32?
  log : Array[String]?
}

///|
pub extend Done with @json.ToJson::{to_json}

///|
pub extend Done with @json.FromJson::{from_json}

///|
fn merge(state : Job, done : Done) -> Job {
  {
    step: done.step.unwrap_or(state.step),
    log: state.log + done.log.unwrap_or([]),
  }
}

///|
/// One directory per thread, one file per checkpoint, one line per task write.
struct FileSaver {
  root : String
}

///|
async fn FileSaver::dir_of(self : FileSaver, thread : String) -> String {
  let dir = self.root + "/" + thread
  @fs.mkdir(dir, recursive=true, allow_exist=true)
  dir
}

///|
async fn FileSaver::ids(self : FileSaver, thread : String) -> Array[String] {
  let dir = self.root + "/" + thread
  let ids = []
  if @fs.exists(dir) {
    for name in @fs.readdir(dir, sort=true) {
      if name.has_suffix(".json") {
        ids.push(name[:name.length() - 5].to_owned())
      }
    }
  }
  ids
}

///|
pub impl @moonstate.Saver for FileSaver with fn get(self, thread, id?) -> @moonstate.Checkpoint? raise {
  let ids = self.ids(thread)
  let wanted = match id {
    Some(want) => if ids.contains(want) { Some(want) } else { None }
    None => ids.last()
  }
  match wanted {
    None => None
    Some(want) => {
      let path = self.root + "/" + thread + "/" + want + ".json"
      let checkpoint : @moonstate.Checkpoint = @json.from_json(
        @json.parse(@fs.read_file(path).text()),
      )
      let writes = []
      let writes_path = self.root + "/" + thread + "/" + want + ".writes"
      if @fs.exists(writes_path) {
        for line in @fs.read_file(writes_path).text().split("\n") {
          if line.length() > 0 {
            let write : @moonstate.TaskWrite = @json.from_json(
              @json.parse(line),
            )
            writes.push(write)
          }
        }
      }
      Some({ ..checkpoint, writes: Some(writes), })
    }
  }
}

///|
pub impl @moonstate.Saver for FileSaver with fn put(self, checkpoint) -> Unit raise {
  let dir = self.dir_of(checkpoint.thread)
  let path = dir + "/" + checkpoint.id + ".json"
  @fs.write_file(
    path,
    @json.to_json({ ..checkpoint, writes: None, }).stringify(),
  )
}

///|
pub impl @moonstate.Saver for FileSaver with fn put_writes(
  self,
  thread,
  id,
  task,
  values,
) -> Unit raise {
  let dir = self.dir_of(thread)
  let line = @json.to_json(@moonstate.TaskWrite::{ task, values, }).stringify()
  @fs.write_file(dir + "/" + id + ".writes", line + "\n", append=true)
}

///|
pub impl @moonstate.Saver for FileSaver with fn list(
  self,
  thread,
  limit?,
  before?,
) -> Array[@moonstate.Checkpoint] raise {
  let kept = []
  for id in self.ids(thread) {
    let is_before = match before {
      Some(before) => id < before
      None => true
    }
    if is_before {
      match self.get(thread, id~) {
        Some(checkpoint) => kept.push(checkpoint)
        None => ()
      }
    }
  }
  match limit {
    Some(want) =>
      if kept.length() > want {
        let cut = []
        for index = kept.length() - want
            index < kept.length()
            index = index + 1 {
          cut.push(kept[index])
        }
        cut
      } else {
        kept
      }
    None => kept
  }
}

///|
pub impl @moonstate.Saver for FileSaver with fn delete(self, thread) -> Unit raise {
  let dir = self.root + "/" + thread
  if @fs.exists(dir) {
    @fs.rmdir(dir, recursive=true)
  }
}

///|
pub extend FileSaver with @moonstate.Saver::{get, put, put_writes, list, delete}

///|
async fn main {
  let args = @env.args()
  let root = if args.length() > 1 {
    args[1]
  } else {
    @fs.tmpdir(prefix="moonstate-example-")
  }
  let graph = @moonstate.Builder::new(merge~, initial={ step: 0, log: [], })
    .entry("plan")
    .node("plan", (_state, _run) => {
      println("plan ran")
      [@moonstate.Write({ step: Some(1), log: Some(["plan"]), })]
    })
    .node("work", (_state, _run) => {
      // Long enough to be interrupted, short enough to keep the example quick.
      @async.sleep(600)
      println("work ran")
      [@moonstate.Write({ step: Some(2), log: Some(["work"]), })]
    })
    .node("report", (_state, _run) => {
      [@moonstate.Write({ step: Some(3), log: Some(["report"]), })]
    })
    .edge("plan", "work")
    .edge("work", "report")
    .compile("job", saver={ root, }) catch {
      refused =>
        abort("the graph does not compile: " + (refused : Error).to_string())
    }
  let out = graph.run({ step: None, log: None, }, thread="job") catch {
    error => abort("the run failed: " + (error : Error).to_string())
  }
  println("done step=" + out.step.to_string() + " log=" + join(out.log))
}

///|
fn join(items : Array[String]) -> String {
  let text = StringBuilder()
  for index = 0; index < items.length(); index = index + 1 {
    if index > 0 {
      text.write_string(", ")
    }
    text.write_string(items[index])
  }
  text.to_string()
}
