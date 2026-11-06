///|
/// The state the graph tests move around: a counter that nodes set, and a log
/// they append to. Two different merge rules on purpose — a number that is
/// replaced and a list that is concatenated — so a merge that folds the wrong
/// way shows up.
#derive(@json.ToJson, @json.FromJson, Debug, Eq)
struct Counter {
  n : Int32
  log : Array[String]
}

///|
pub extend Counter with @json.ToJson::{to_json}

///|
pub extend Counter with @json.FromJson::{from_json}

///|
pub extend Counter with Debug::{to_repr}

///|
pub extend Counter with Eq::{equal, not_equal}

///|
/// What a node writes back. Every field is optional so a node writes only what it
/// touched, which is what makes parallel writes mergeable.
#derive(@json.ToJson, @json.FromJson, Debug, Eq)
struct Patch {
  n : Int32?
  log : Array[String]?
}

///|
pub extend Patch with @json.ToJson::{to_json}

///|
pub extend Patch with @json.FromJson::{from_json}

///|
pub extend Patch with Debug::{to_repr}

///|
pub extend Patch with Eq::{equal, not_equal}

///|
/// A state with nothing written yet, the `initial` every test graph starts from.
fn zero() -> Counter {
  { n: 0, log: [], }
}

///|
fn counter(n : Int32, log : Array[String]) -> Counter {
  { n, log, }
}

///|
fn merge_patch(state : Counter, update : Patch) -> Counter {
  { n: update.n.unwrap_or(state.n), log: state.log + update.log.unwrap_or([]), }
}

///|
fn count(n : Int32, tag : String) -> Patch {
  { n: Some(n), log: Some([tag]), }
}

///|
fn add(tag : String) -> Patch {
  { n: None, log: Some([tag]), }
}

///|
fn seed(n : Int32) -> Patch {
  { n: Some(n), log: None, }
}

///|
fn counter_builder() -> @moonstate.Builder[Counter, Patch] {
  @moonstate.Builder::new(merge=merge_patch, initial=zero())
}
