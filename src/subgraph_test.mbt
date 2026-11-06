///|
/// The state of the nested graph: it counts hits, so `enter` and `leave` have
/// something to convert between.
#derive(@json.ToJson, @json.FromJson, Debug, Eq)
struct Tally {
  hits : Int32
}

///|
pub extend Tally with @json.ToJson::{to_json}

///|
pub extend Tally with @json.FromJson::{from_json}

///|
pub extend Tally with Debug::{to_repr}

///|
pub extend Tally with Eq::{equal, not_equal}

///|
#derive(@json.ToJson, @json.FromJson, Debug, Eq)
struct Bump {
  by : Int32?
}

///|
pub extend Bump with @json.ToJson::{to_json}

///|
pub extend Bump with @json.FromJson::{from_json}

///|
pub extend Bump with Debug::{to_repr}

///|
pub extend Bump with Eq::{equal, not_equal}

///|
fn merge_bump(state : Tally, update : Bump) -> Tally {
  { hits: state.hits + update.by.unwrap_or(0), }
}

///|
/// A child graph of one node that adds two to whatever it is given.
fn child() -> @moonstate.Graph[Tally, Bump] {
  @moonstate.Builder::new(merge=merge_bump, initial={ hits: 0, })
  .node("bump", (_state, _run) => [@moonstate.Write({ by: Some(2), })])
  .compile("child") catch {
    refused => abort("refused: " + (refused : Error).to_string())
  }
}

///|
/// A parent graph whose one node is the child: the parent's counter becomes the
/// child's hits, and the child's result comes back as the parent's write.
fn parent_with_child() -> @moonstate.Graph[Counter, Patch] {
  counter_builder()
  .entry("kid")
  .subgraph("kid", child(), enter=state => ({ hits: state.n, } : Tally), leave=tally => {
    count(tally.hits, "child")
  })
  .compile("parent") catch {
    refused => abort("refused: " + (refused : Error).to_string())
  }
}

///|
async test "a subgraph runs its own graph and its result comes back" {
  let graph = parent_with_child()
  let out = graph.run(seed(5)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out.n, 7)
  assert_eq(out.log, ["child"])
}

///|
async test "a subgraph gets its own checkpoints under a nested thread" {
  let saver = @moonstate.MemorySaver::new()
  let graph = counter_builder()
    .entry("kid")
    .subgraph("kid", child(), enter=state => ({ hits: state.n, } : Tally), leave=tally => {
      count(tally.hits, "child")
    })
    .compile("parent", saver~) catch {
      refused => abort("refused: " + (refused : Error).to_string())
    }
  let _ = graph.run(seed(5), thread="t") catch {
    error => fail("run: " + (error : Error).to_string())
  }
  // The parent thread names the child's thread after its own checkpoint, so the
  // two runs of a re-entered node never share checkpoints.
  let child_history = saver.list("t|kid@cp-000000") catch {
    error => fail("list: " + (error : Error).to_string())
  }
  assert_eq(child_history.length(), 2)
  let parent_history = graph.history("t") catch {
    error => fail("history: " + (error : Error).to_string())
  }
  assert_eq(parent_history.length(), 2)
}
