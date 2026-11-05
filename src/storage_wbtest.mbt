// Agent state storage (Koog `AIAgentStorage`).

///|
test "agent storage: set/get round-trips typed values through Json" {
  let store = AgentStorage::new()
  store.set("count", 42)
  store.set("name", "leo")
  store.set("ratio", 0.5)
  // Values come back at the type requested at the call site.
  assert_eq((store.get("count") : Int32?), Some(42))
  assert_eq((store.get("name") : String?), Some("leo"))
  assert_eq((store.get("ratio") : Double?), Some(0.5))
  // Absent key, and a value whose stored Json does not decode to the requested type.
  assert_eq((store.get("missing") : Int32?), None)
  assert_eq((store.get("name") : Int32?), None)
}

///|
test "agent storage: contains, remove, clear, size" {
  let store = AgentStorage::new()
  store.set("a", 1)
  store.set("b", 2)
  assert_eq(store.size(), 2)
  assert_eq(store.contains("a"), true)
  assert_eq(store.contains("z"), false)
  assert_eq(store.remove("a"), true)
  assert_eq(store.remove("a"), false)
  assert_eq((store.get("a") : Int32?), None)
  assert_eq(store.size(), 1)
  store.clear()
  assert_eq(store.size(), 0)
}
