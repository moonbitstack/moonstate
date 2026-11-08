///|
/// A row that could not be read back into the record it was written from: a
/// checkpoint's state, a task's steps, a store item, or a column that is null when
/// the record needs it.
pub(all) suberror Failed {
  Unreadable(column~ : String, reason~ : String)
}

///|
/// The text an error carries, for the `Backend` a caller ends up matching on.
pub fn Failed::report(self : Failed) -> String {
  match self {
    Unreadable(column~, reason~) => "column '" + column + "': " + reason
  }
}
