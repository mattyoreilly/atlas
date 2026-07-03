# The code-execution core: what the agent's hands actually do.
run <- Atlas:::atlas_run_code

test_that("state persists between calls and data is reachable", {
  env <- new.env(parent = globalenv())
  env$data <- mtcars
  run("x <- 40", env)
  expect_equal(run("x + 2", env), "[1] 42")
  expect_match(run("nrow(data)", env), "32")
})

test_that("errors and warnings come back as text, not conditions", {
  env <- new.env(parent = globalenv())
  expect_match(run("stop('boom')", env), "^Error: boom")
  expect_match(run("warning('careful')", env), "^Warning: careful")
})

test_that("long output is truncated", {
  env <- new.env(parent = globalenv())
  out <- run("seq_len(1e5)", env)
  expect_lt(nchar(out), 9000)
  expect_match(out, "truncated")
})

test_that("multi-expression chunks print visible results only", {
  env <- new.env(parent = globalenv())
  out <- run("a <- 1\nb <- 2\na + b", env)
  expect_equal(out, "[1] 3")
  expect_equal(run("invisible(9)", env), "(no output)")
})
