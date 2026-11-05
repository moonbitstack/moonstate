///|
fn render(f : @moonstate.Fact) -> String {
  match f {
    SingleFact(concept~, value~, ..) => concept.keyword + " = " + value
    MultipleFacts(concept~, values~, ..) =>
      concept.keyword + " = [" + values.join(", ") + "]"
  }
}

///|
/// Agent memory (Koog `agents-features-memory`): facts about a subject, held under
/// a scope. A `Concept` names what is remembered and whether it is single- or
/// multi-valued; `load` filters by concept, `load_all` returns a whole bucket, and
/// buckets are isolated by `MemorySubject` and `MemoryScope`.
///
///     moon run examples/20-memory --target native
#coverage.skip
fn main {
  let mem = @moonstate.InMemoryProvider::new()
  let name : @moonstate.Concept = {
    keyword: "user_name",
    description: "the user's name",
    fact_type: Single,
  }
  let hobbies : @moonstate.Concept = {
    keyword: "hobbies",
    description: "the user's hobbies",
    fact_type: Multiple,
  }

  // Save into the user/product bucket.
  mem.save(
    SingleFact(concept=name, value="lfanke", timestamp=233L),
    @moonstate.subject_user,
    ScopeProduct,
  )
  mem.save(
    MultipleFacts(concept=hobbies, values=["chess", "hiking"], timestamp=234L),
    @moonstate.subject_user,
    ScopeProduct,
  )
  println(
    "subject '\{@moonstate.subject_user.name}' priority=\{@moonstate.subject_user.priority}",
  )

  // load filters by concept; load_all returns the bucket.
  for f in mem.load(name, @moonstate.subject_user, ScopeProduct) {
    println("load(user_name): " + render(f))
  }
  println(
    "load_all(user/product): \{mem.load_all(@moonstate.subject_user, ScopeProduct).length()} fact(s)",
  )
  for f in mem.load_all(@moonstate.subject_user, ScopeProduct) {
    println("  " + render(f))
  }

  // A different subject or scope is a different, empty bucket.
  println(
    "load(user_name) for machine subject: \{mem.load(name, @moonstate.subject_machine, ScopeProduct).length()} fact(s)",
  )
  println(
    "load(user_name) in agent scope: \{mem.load(name, @moonstate.subject_user, ScopeAgent("assistant")).length()} fact(s)",
  )
}
