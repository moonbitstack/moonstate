///|
/// The three tables this package keeps, so that two savers can share one database
/// without sharing one set of names.
pub(all) struct Names {
  ///
  /// One row per checkpoint.
  checkpoint : String
  ///
  /// One row per task that finished inside a superstep.
  write : String
  ///
  /// One row per key of the long-term store.
  item : String
}

///|
/// The names a saver and a store take when nothing else is asked for.
pub let names : Names = {
  checkpoint: "moonstate_checkpoint",
  write: "moonstate_write",
  item: "moonstate_item",
}

///|
/// The preset, reachable from a function whose `names` parameter would otherwise
/// hide the value of the same name.
fn preset_names() -> Names {
  names
}
