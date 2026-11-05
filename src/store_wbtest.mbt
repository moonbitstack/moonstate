///|
/// A single-fact concept for the user's name.
fn user_name() -> Concept {
  { keyword: "user_name", description: "the user's name", fact_type: Single, }
}

///|
test "save then load a single fact by concept" {
  let mem = InMemoryProvider::new()
  let c = user_name()
  mem.save(
    SingleFact(concept=c, value="Ann", timestamp=100),
    subject_user,
    ScopeProduct,
  )
  let facts = mem.load(c, subject_user, ScopeProduct)
  assert_eq(facts.length(), 1)
  assert_eq(facts[0], SingleFact(concept=c, value="Ann", timestamp=100))
}

///|
test "facts are isolated by subject and by scope" {
  let mem = InMemoryProvider::new()
  let c = user_name()
  mem.save(
    SingleFact(concept=c, value="Ann", timestamp=1),
    subject_user,
    ScopeProduct,
  )
  // A different subject or a different scope is a different bucket.
  assert_eq(mem.load(c, subject_machine, ScopeProduct).length(), 0)
  assert_eq(mem.load(c, subject_user, ScopeCrossProduct).length(), 0)
  // The original bucket still has it.
  assert_eq(mem.load(c, subject_user, ScopeProduct).length(), 1)
}

///|
test "load filters by concept; load_all returns the whole bucket" {
  let mem = InMemoryProvider::new()
  let name = user_name()
  let city = {
    keyword: "user_city",
    description: "where the user lives",
    fact_type: Single,
  }
  mem.save(
    SingleFact(concept=name, value="Ann", timestamp=1),
    subject_user,
    ScopeProduct,
  )
  mem.save(
    SingleFact(concept=city, value="Paris", timestamp=2),
    subject_user,
    ScopeProduct,
  )
  assert_eq(mem.load(name, subject_user, ScopeProduct).length(), 1)
  assert_eq(mem.load(city, subject_user, ScopeProduct).length(), 1)
  assert_eq(mem.load_all(subject_user, ScopeProduct).length(), 2)
}

///|
test "a multiple-facts concept round-trips" {
  let mem = InMemoryProvider::new()
  let c = {
    keyword: "hobbies",
    description: "the user's hobbies",
    fact_type: Multiple,
  }
  mem.save(
    MultipleFacts(concept=c, values=["chess", "hiking"], timestamp=5),
    subject_user,
    ScopeAgent("assistant"),
  )
  let facts = mem.load(c, subject_user, ScopeAgent("assistant"))
  assert_eq(facts.length(), 1)
  assert_eq(
    facts[0],
    MultipleFacts(concept=c, values=["chess", "hiking"], timestamp=5),
  )
}
