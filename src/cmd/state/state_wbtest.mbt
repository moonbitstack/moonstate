///|
fn generate(source : String) -> String raise {
  @gen.render(State::{ }, [("state.mbt", source)])
}

///|
test "a record gets a patch of options and a merge that replaces by default" {
  let code = generate(
    (
      #|#state.patch
      #|pub(all) struct Counter {
      #|  n : Int
      #|  #state.append
      #|  log : Array[String]
      #|}
    ),
  )
  assert_true(code.contains("pub(all) struct CounterPatch"))
  assert_true(code.contains("n : Int?"))
  assert_true(code.contains("log : Array[String]?"))
  assert_true(
    code.contains(
      "pub fn merge_counter(state : Counter, patch : CounterPatch) -> Counter",
    ),
  )
  assert_true(code.contains("n: match patch.n {"))
  assert_true(code.contains("Some(value) => state.log + value"))
}

///|
test "a field adds, or folds by a function of the program's own" {
  let code = generate(
    (
      #|#state.patch
      #|struct Tally {
      #|  #state.add
      #|  count : Int
      #|  #state.with(@keep.longest)
      #|  best : String
      #|}
    ),
  )
  assert_true(code.contains("struct TallyPatch"))
  assert_false(code.contains("pub(all) struct TallyPatch"))
  assert_true(code.contains("Some(value) => state.count + value"))
  assert_true(code.contains("Some(value) => @keep.longest(state.best, value)"))
}

///|
test "two reducers on one field are refused" {
  let refused = try {
    ignore(
      generate(
        (
          #|#state.patch
          #|struct Odd {
          #|  #state.add
          #|  #state.append
          #|  n : Int
          #|}
        ),
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}

///|
test "the annotation goes on a record" {
  let refused = try {
    ignore(
      generate(
        (
          #|#state.patch
          #|fn f() -> Unit {
          #|  ()
          #|}
        ),
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}
