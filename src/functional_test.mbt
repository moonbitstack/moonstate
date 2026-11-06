///|
async test "an entrypoint runs its tasks in order and returns what the body returns" {
  let ran : Array[String] = []
  let plus_one = @moonstate.task("plus_one", (n : Int32) => {
    ran.push("plus_one")
    n + 1
  })
  let twice = @moonstate.task("twice", (n : Int32) => {
    ran.push("twice")
    n * 2
  })
  let workflow = @moonstate.entrypoint("math", async fn(
    n : Int32,
    ctx : @moonstate.Context,
  ) -> Int32 {
    let first = plus_one.call(ctx, n)
    twice.call(ctx, first)
  }) catch {
    refused => abort("refused: " + (refused : Error).to_string())
  }
  let out = workflow.run(3) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out, 8)
  assert_eq(ran, ["plus_one", "twice"])
}

///|
async test "a task result that was already recorded is not computed again" {
  let calls = Ref(0)
  let blocked = Ref(true)
  let first = @moonstate.task("first", (n : Int32) => {
    calls.val = calls.val + 1
    n + 10
  })
  let second = @moonstate.task("second", (n : Int32) => n * 2)
  let saver = @moonstate.MemorySaver::new()
  let workflow = @moonstate.entrypoint(
    "crashing",
    async fn(n : Int32, ctx : @moonstate.Context) -> Int32 {
      let a = first.call(ctx, n)
      if blocked.val {
        raise Failure::Failure("the process went away")
      }
      let b = second.call(ctx, a)
      a + b
    },
    saver~,
  ) catch {
    refused => abort("refused: " + (refused : Error).to_string())
  }
  let message = try {
    workflow.run(1, thread="t") |> ignore
    "no failure"
  } catch {
    @moonstate.NodeFailed(..) => "failed"
    error => "other: " + (error : Error).to_string()
  }
  assert_eq(message, "failed")
  assert_eq(calls.val, 1)
  // The second attempt replays the body: the first task reports what it recorded
  // instead of running again, and the run reaches its end.
  blocked.val = false
  let out = workflow.run(1, thread="t") catch {
    error => fail("second run: " + (error : Error).to_string())
  }
  assert_eq(out, 33)
  assert_eq(calls.val, 1)
}

///|
async test "a task with a retry policy is tried again before it fails the run" {
  let tries = Ref(0)
  let flaky = @moonstate.task(
    "flaky",
    (n : Int32) => {
      tries.val = tries.val + 1
      if tries.val < 3 {
        raise Failure::Failure("not yet")
      }
      n * 3
    },
    retry=@moonstate.Retry::{ attempts: 3, delay: 0, },
  )
  let workflow = @moonstate.entrypoint("retrying", async fn(
    n : Int32,
    ctx : @moonstate.Context,
  ) -> Int32 {
    flaky.call(ctx, n)
  }) catch {
    refused => abort("refused: " + (refused : Error).to_string())
  }
  let out = workflow.run(2) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out, 6)
  assert_eq(tries.val, 3)
}

///|
async test "a task that never succeeds fails the run with its name" {
  let hopeless = @moonstate.task(
    "hopeless",
    (_n : Int32) => raise Failure::Failure("never"),
    retry=@moonstate.Retry::{ attempts: 2, delay: 0, },
  )
  let workflow = @moonstate.entrypoint("doomed", async fn(
    n : Int32,
    ctx : @moonstate.Context,
  ) -> Int32 {
    hopeless.call(ctx, n)
  }) catch {
    refused => abort("refused: " + (refused : Error).to_string())
  }
  let message = try {
    workflow.run(1) |> ignore
    "no failure"
  } catch {
    @moonstate.NodeFailed(node~, message~) => node + ": " + message
    error => "other: " + (error : Error).to_string()
  }
  assert_eq(message, "entrypoint: node 'hopeless' failed: never")
}
