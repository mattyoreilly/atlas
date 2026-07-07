# The code-execution core: what the agent's hands actually do.
run <- atlas:::atlas_run_code

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

  tiny <- run("'abcdefghij'", env, max_chars = 5)
  expect_match(tiny, "truncated")
  expect_match(tiny, "^\\[1\\] \"")
})

test_that("syntax errors come back as text too", {
  env <- new.env(parent = globalenv())
  expect_match(run("lm(mpg ~", env), "^Error:")
})

test_that("tabular results render as markdown tables", {
  env <- new.env(parent = globalenv())
  env$data <- mtcars

  # named vector (colSums-style)
  out <- run("colSums(is.na(data[1:3]))", env)
  expect_match(out, "| name | value |", fixed = TRUE)
  expect_match(out, "| mpg | 0 |", fixed = TRUE)

  # 1-D table() and summary()
  expect_match(run("table(data$cyl)", env), "| 4 | 11 |", fixed = TRUE)
  expect_match(run("summary(data$mpg)", env), "| Median |", fixed = TRUE)

  # 2-D table keeps its row labels
  out2 <- run("table(data$cyl, data$am)", env)
  expect_match(out2, "|   | 0 | 1 |", fixed = TRUE)
  expect_match(out2, "| 8 | 12 | 2 |", fixed = TRUE)

  # data.frames become tables, long ones are truncated with a note
  expect_match(run("data.frame(a = 1:2, b = c('x', 'y'))", env),
               "| a | b |", fixed = TRUE)
  long <- run("data.frame(i = 1:100)", env)
  expect_match(long, "and 70 more rows")

  # scalars and unnamed vectors still print plainly
  expect_match(run("1 + 1", env), "\\[1\\] 2")
  # summary(data.frame) is a character 'table' of padded strings: keep as text
  expect_no_match(run("summary(data[1:3])", env), "\\|")
  # side-effect output (cat) is preserved alongside a table
  both <- run("cat('note\\n'); table(data$vs)", env)
  expect_match(both, "note")
  expect_match(both, "| name | value |", fixed = TRUE)
})

test_that("consecutive text output coalesces into one segment", {
  env <- new.env(parent = globalenv())
  env$data <- mtcars
  segs <- atlas:::atlas_run_segments(
    "cat('one\\n')\ncat('two\\n')\n1 + 1\ncat('three\\n')", env)
  expect_length(segs, 1)  # all plain text: one block, not four
  expect_equal(segs[[1]]$lines, c("one", "two", "[1] 2", "three"))

  # tables still split the text around them
  segs2 <- atlas:::atlas_run_segments("cat('before\\n')\ntable(data$vs)", env)
  expect_length(segs2, 2)
  expect_equal(segs2[[1]]$type, "text")
  expect_equal(segs2[[2]]$type, "table")
})

test_that("console display shows tables as aligned R output, not pipes", {
  s <- new_session()  # display = "console"
  shown <- paste(capture.output(
    res <- s$chat$get_tools()$run_r_code("table(data$cyl)")), collapse = "\n")
  expect_match(shown, "#> +name value")
  expect_match(shown, "#> +4 +11")
  expect_no_match(shown, "\\|")
})

test_that("markdown display renders tables outside code fences", {
  s <- new_session(display = "markdown")
  shown <- paste(capture.output(
    res <- s$chat$get_tools()$run_r_code("table(data$cyl)")), collapse = "\n")
  expect_match(shown, "\\| 4 \\| 11 \\|")
  # the table itself is not wrapped in a fence
  expect_no_match(shown, "```\n\\|")
})

test_that("multi-expression chunks print visible results only", {
  env <- new.env(parent = globalenv())
  out <- run("a <- 1\nb <- 2\na + b", env)
  expect_equal(out, "[1] 3")
  expect_equal(run("invisible(9)", env), "(no output)")
})
