# Session persistence and wiring. FakeChat-driven loop tests live in
# test-atlas.R; these use a real (never-called) ellmer chat.

test_that("initialize validates inputs", {
  expect_error(AtlasSession$new(mtcars, "not_a_col", chat = real_chat(),
                                dir = temp_dir()),
               "not a column")
  expect_error(AtlasSession$new("not data", "mpg", chat = real_chat(),
                                dir = temp_dir()))
})

test_that("session writes its inputs and checkpoints to the run dir", {
  dir <- temp_dir()
  s <- new_session(dir)
  expect_true(file.exists(file.path(dir, "data.rds")))
  meta <- readRDS(file.path(dir, "meta.rds"))
  expect_equal(meta$outcome, "mpg")
  expect_equal(meta$n_models, 2)

  s$code <- c("m <- lm(mpg ~ wt, data)", "rsq <- summary(m)$r.squared")
  s$checkpoint()
  expect_equal(readRDS(file.path(dir, "code.rds")), s$code)
  expect_match(paste(readLines(file.path(dir, "code.R")), collapse = "\n"),
               "lm\\(mpg ~ wt")
  expect_true(file.exists(file.path(dir, "turns.rds")))
})

test_that("stopping rules are validated, stored, and reach the system prompt", {
  expect_error(new_session(patience = 0), "patience")
  expect_error(new_session(min_improve = -1), "min_improve")
  expect_error(new_session(min_improve = 5), "min_improve")  # fraction, not %

  dir <- temp_dir()
  s <- new_session(dir, patience = 4, min_improve = 0.025)
  meta <- readRDS(file.path(dir, "meta.rds"))
  expect_equal(meta$patience, 4)
  expect_equal(meta$min_improve, 0.025)
  expect_match(s$chat$get_system_prompt(), "4 consecutive attempts")
  expect_match(s$chat$get_system_prompt(), "2.5% \\(relative\\)")
  expect_match(s$chat$get_system_prompt(), "up to 2 distinct candidate models")

  # and they survive a resume
  s$checkpoint()
  r <- atlas_resume(dir, chat = real_chat())
  expect_match(r$chat$get_system_prompt(), "4 consecutive attempts")
})

test_that("the atlas.dir option controls where runs are saved", {
  base <- temp_dir()
  old <- options(atlas.dir = base)
  on.exit(options(old))
  s <- AtlasSession$new(mtcars, "mpg", chat = real_chat())
  expect_true(startsWith(s$dir, base))
  expect_true(file.exists(file.path(s$dir, "data.rds")))

  # explicit dir still wins, and ~ is expanded
  s2 <- AtlasSession$new(mtcars, "mpg", chat = real_chat(),
                         dir = file.path(base, "explicit"))
  expect_equal(s2$dir, file.path(base, "explicit"))
})

test_that("atlas_resume forwards front-end options like on_ask", {
  dir <- temp_dir()
  s <- new_session(dir)
  s$checkpoint()
  r <- atlas_resume(dir, chat = real_chat(),
                    on_ask = function(q) "answered elsewhere")
  expect_equal(r$chat$get_tools()$ask_user(question = "hm?"),
               "answered elsewhere")
})

test_that("atlas_resume replays the code log and reconstructs the environment", {
  dir <- temp_dir()
  s <- new_session(dir)
  s$code <- c("set.seed(1)", "m <- lm(mpg ~ wt, data)",
              "atlas_models <- list(lm = m)",
              "atlas_leaderboard <- data.frame(name = 'lm', type = 'regression',
                 metric = 'rmse', value = 3, notes = 'baseline')")
  for (chunk in s$code) Atlas:::atlas_run_code(chunk, s$env)
  s$checkpoint()

  r <- atlas_resume(dir, chat = real_chat())
  expect_equal(r$code, s$code)
  expect_s3_class(r$env$atlas_models$lm, "lm")
  expect_equal(coef(r$env$atlas_models$lm), coef(s$env$atlas_models$lm))
  expect_equal(r$env$atlas_leaderboard$name, "lm")
})

test_that("run_r_code tool logs, checkpoints, and prints readable blocks", {
  dir <- temp_dir()
  s <- new_session(dir)
  run_tool <- s$chat$get_tools()$run_r_code
  shown <- capture.output(res <- run_tool("  \n1 + 1\n"))
  expect_equal(res, "[1] 2")
  expect_equal(s$code, "1 + 1")
  expect_true(any(grepl("1 \\+ 1", shown)))
  expect_true(any(grepl("#> \\[1\\] 2", shown)))
  expect_true(file.exists(file.path(dir, "code.rds")))
})

test_that("interjections reach the agent through the next tool result", {
  queue <- "use a log scale for the target"
  s <- new_session(interject = function() {
    msg <- queue
    queue <<- NULL
    msg
  })
  run_tool <- s$chat$get_tools()$run_r_code

  shown <- capture.output(out <- run_tool("1 + 1"))
  expect_match(out, "MESSAGE FROM THE USER")
  expect_match(out, "log scale for the target")
  expect_match(out, "^\\[1\\] 2")  # the real result still comes first
  # the message is echoed to the display (cli rule label goes to stderr)
  expect_match(paste(shown, collapse = "\n"), "log scale for the target")

  # queue drained: next call is clean
  out2 <- run_tool("2 + 2")
  expect_no_match(out2, "MESSAGE FROM THE USER")

  # the system prompt only mentions interjections when the hook is present
  expect_match(s$chat$get_system_prompt(), "MESSAGE FROM THE USER")
  expect_no_match(new_session()$chat$get_system_prompt(),
                  "MESSAGE FROM THE USER")
})

test_that("ask_user degrades gracefully when not interactive", {
  skip_if(interactive())
  s <- new_session()
  ans <- s$chat$get_tools()$ask_user(question = "approve the plan?")
  expect_match(ans, "not available")
  expect_match(ans, "best judgment")
})

test_that("results() bundles models, leaderboard, and code", {
  s <- new_session()
  expect_warning(s$results(), "atlas_models")

  s$env$atlas_models <- list(lm = lm(mpg ~ wt, mtcars))
  s$env$atlas_leaderboard <- data.frame(name = "lm", metric = "rmse", value = 3)
  res <- s$results()
  expect_s3_class(res, "atlas")
  expect_s3_class(res$models$lm, "lm")
  expect_identical(res$session, s)
  expect_output(print(res), "rmse")
})

test_that("session print gives a status line", {
  s <- new_session()
  expect_output(print(s), "0 code chunks run")
  expect_output(print(s), "no models yet")
  s$code <- "x <- 1"
  s$env$atlas_models <- list(m = lm(mpg ~ wt, mtcars))
  expect_output(print(s), "1 code chunks run")
  expect_output(print(s), "1 models built")
})
