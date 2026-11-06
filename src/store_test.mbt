///|
async test "a store keeps namespaced values apart" {
  let store = @moonstate.MemoryStore::new()
  store.put(["users", "alice"], "email", Json("a@example.com")) catch {
    error => fail("put: " + (error : Error).to_string())
  }
  store.put(["users", "bob"], "email", Json("b@example.com")) catch {
    error => fail("put: " + (error : Error).to_string())
  }
  let found = store.get(["users", "alice"], "email") catch {
    error => fail("get: " + (error : Error).to_string())
  }
  assert_eq(found.unwrap().value, Json("a@example.com"))
}

///|
async test "search finds everything under a namespace" {
  let store = @moonstate.MemoryStore::new()
  store.put(["notes"], "one", Json({ "text": "first note" })) catch {
    error => fail("put: " + (error : Error).to_string())
  }
  store.put(["notes", "inner"], "two", Json({ "text": "second note" })) catch {
    error => fail("put: " + (error : Error).to_string())
  }
  store.put(["other"], "three", Json({ "text": "unrelated" })) catch {
    error => fail("put: " + (error : Error).to_string())
  }
  let found = store.search(["notes"]) catch {
    error => fail("search: " + (error : Error).to_string())
  }
  assert_eq(found.length(), 2)
}

///|
async test "search narrows by query text and by filter" {
  let store = @moonstate.MemoryStore::new()
  store.put(["notes"], "one", Json({ "text": "first note", "tag": "a" })) catch {
    error => fail("put: " + (error : Error).to_string())
  }
  store.put(["notes"], "two", Json({ "text": "second note", "tag": "b" })) catch {
    error => fail("put: " + (error : Error).to_string())
  }
  let by_text = store.search(["notes"], query="second") catch {
    error => fail("search: " + (error : Error).to_string())
  }
  assert_eq(by_text.length(), 1)
  assert_eq(by_text[0].key, "two")
  let by_tag = store.search(["notes"], filter=Map([("tag", Json("a"))])) catch {
    error => fail("search: " + (error : Error).to_string())
  }
  assert_eq(by_tag.length(), 1)
  assert_eq(by_tag[0].key, "one")
}

///|
async test "search honours the limit and delete removes a value" {
  let store = @moonstate.MemoryStore::new()
  for i = 0; i < 5; i = i + 1 {
    store.put(["notes"], "k" + i.to_string(), Json(i)) catch {
      error => fail("put: " + (error : Error).to_string())
    }
  }
  let found = store.search(["notes"], limit=2) catch {
    error => fail("search: " + (error : Error).to_string())
  }
  assert_eq(found.length(), 2)
  store.delete(["notes"], "k0") catch {
    error => fail("delete: " + (error : Error).to_string())
  }
  let after = store.get(["notes"], "k0") catch {
    error => fail("get: " + (error : Error).to_string())
  }
  match after {
    None => ()
    Some(item) =>
      fail("k0 should be gone, still holds " + item.value.stringify())
  }
}

///|
async test "a node reaches the store through its run handle" {
  let store = @moonstate.MemoryStore::new()
  let graph = counter_builder()
    .entry("remember")
    .node("remember", (state, run) => {
      match run.store() {
        Some(store) =>
          store.put(["runs"], "last", Json(state.n)) catch {
            error => abort("put: " + (error : Error).to_string())
          }
        None => abort("the graph was compiled with a store")
      }
      [@moonstate.Write(add("remember"))]
    })
    .compile("store", store~) catch {
      refused => abort("refused: " + (refused : Error).to_string())
    }
  let _ = graph.run(seed(3)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  let kept = store.get(["runs"], "last") catch {
    error => fail("get: " + (error : Error).to_string())
  }
  assert_eq(kept.unwrap().value, Json(3))
}
