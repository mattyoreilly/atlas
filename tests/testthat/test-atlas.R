# The full agentic loop, end to end, driven by a scripted FakeChat.

test_that("build() runs the loop, verifies constraints, and repairs violations", {
  dir <- temp_dir()
  chat <- FakeChat$new(list(
    # turn 1: agent "builds" a model that violates uses_wt
    list(
      calls = list(
        list(tool = "run_r_code",
             args = list(code = "atlas_models <- list(lm1 = lm(mpg ~ hp, data))")),
        list(tool = "run_r_code",
             args = list(code = paste(
               "atlas_leaderboard <- data.frame(name = 'lm1',",
               "metric = 'rmse', value = 3.2, notes = 'baseline')")))
      ),
      reply = "# Report\n\nBuilt lm1 from hp."
    ),
    # turn 2: the repair round refits with wt
    list(
      calls = list(
        list(tool = "run_r_code",
             args = list(code = "atlas_models$lm1 <- lm(mpg ~ hp + wt, data)"))
      ),
      reply = "Refit lm1 with wt; constraint now satisfied."
    )
  ))

  s <- AtlasSession$new(mtcars, "mpg", n_models = 1,
                        constraints = list(uses_wt = con_uses("wt")),
                        chat = chat, dir = dir)
  res <- s$build(verbose = FALSE, refine = FALSE, validate = FALSE)

  # one build prompt + one repair prompt, with the violation spelled out
  expect_length(chat$log, 2)
  expect_match(chat$log[1], "Build up to 1 models predicting `mpg`")
  expect_match(chat$log[1], "Hard constraints")
  expect_match(chat$log[2], "constraint 'uses_wt'")
  expect_match(chat$log[2], "does not use")

  expect_s3_class(res, "atlas")
  expect_true(all(res$constraints$passed))
  expect_true("wt" %in% names(coef(res$models$lm1)))
  expect_equal(res$report, "Refit lm1 with wt; constraint now satisfied.")

  # artifacts land in the run directory
  expect_equal(paste(readLines(file.path(dir, "report.md")), collapse = "\n"),
               res$report)
  expect_equal(utils::read.csv(file.path(dir, "leaderboard.csv"))$name, "lm1")
  expect_s3_class(readRDS(file.path(dir, "models.rds"))$lm1, "lm")
})

test_that("build() gives up after max_fix_rounds and reports what's unmet", {
  chat <- FakeChat$new(list(
    list(
      calls = list(
        list(tool = "run_r_code",
             args = list(code = paste(
               "atlas_models <- list(m = lm(mpg ~ hp, data));",
               "atlas_leaderboard <- data.frame(name = 'm', metric = 'rmse', value = 4)")))
      ),
      reply = "built"
    ),
    list(reply = "cannot fix it"),
    list(reply = "still cannot fix it")
  ))
  s <- AtlasSession$new(mtcars, "mpg",
                        constraints = list(uses_wt = con_uses("wt")),
                        chat = chat, dir = temp_dir())
  res <- s$build(verbose = FALSE, max_fix_rounds = 2, refine = FALSE,
                 validate = FALSE)

  expect_length(chat$log, 3) # build + exactly two repair attempts
  expect_false(all(res$constraints$passed))
  expect_output(print(res), "uses_wt")  # the failing row is shown
})

test_that("atlas() wrapper returns a complete results object", {
  chat <- FakeChat$new(list(
    list(
      calls = list(
        list(tool = "run_r_code",
             args = list(code = paste(
               "atlas_models <- list(m = lm(mpg ~ wt, data));",
               "atlas_leaderboard <- data.frame(name = 'm', metric = 'rmse', value = 2.9)")))
      ),
      reply = "report text"
    )
  ))
  res <- atlas(mtcars, "mpg", chat = chat, dir = temp_dir(), verbose = FALSE,
               refine = FALSE, validate = FALSE)

  expect_s3_class(res, "atlas")
  expect_s3_class(res$models$m, "lm")
  expect_equal(res$report, "report text")
  expect_equal(res$leaderboard$value, 2.9)
  expect_s3_class(res$session, "AtlasSession")
  expect_match(res$code[1], "atlas_models")
})

test_that("build() requests modelblueprint validation for the winner", {
  skip_if_not_installed("modelblueprint")
  dir <- temp_dir()
  chat <- FakeChat$new(list(
    list(
      calls = list(list(tool = "run_r_code", args = list(code = paste(
        "atlas_models <- list(m = lm(mpg ~ wt, data));",
        "atlas_leaderboard <- data.frame(name = 'm', metric = 'rmse', value = 2.9)")))),
      reply = "built"
    ),
    list(reply = "validation files written")
  ))
  s <- AtlasSession$new(mtcars, "mpg", chat = chat, dir = dir)
  s$build(verbose = FALSE, refine = FALSE)

  expect_length(chat$log, 2)
  expect_match(chat$log[2], "modelblueprint::model_validation")
  expect_match(chat$log[2], dir, fixed = TRUE)
  expect_match(chat$log[2], "x_original_inputs")
  # the canonical persistence workflow, not ad-hoc saveRDS/READMEs
  expect_match(chat$log[2], "loadmb")
  expect_match(chat$log[2], "mb_dashboard")
  expect_match(chat$log[2], "Do NOT create any other artifacts")
})

test_that("autonomous run with test_prop ends in an ungameable test ranking", {
  dir <- temp_dir()
  chat <- FakeChat$new(list(
    list(
      calls = list(list(tool = "run_r_code", args = list(code = paste(
        "atlas_models <- list(m1 = lm(mpg ~ wt, data), m2 = lm(mpg ~ 1, data));",
        "atlas_leaderboard <- data.frame(name = c('m1', 'm2'),",
        "  metric = 'rmse', value = c(3, 6))")))),
      reply = "built autonomously"
    )
  ))
  res <- atlas(mtcars, "mpg", chat = chat, dir = dir, verbose = FALSE,
               refine = FALSE, validate = FALSE,
               autonomous = TRUE, test_prop = 0.25)

  # the models were trained on the 24 held-in rows only
  expect_equal(nobs(res$models$m1), 24)

  lb <- res$test_leaderboard
  expect_s3_class(lb, "data.frame")
  expect_equal(nrow(lb), 2)
  expect_equal(lb$model[1], "m1")   # real model beats intercept on test
  expect_true(file.exists(file.path(dir, "test_leaderboard.csv")))
  # test table is printed (rule labels go to stderr under testthat)
  expect_output(print(res), "m1 +rmse +2\\.")

  # autonomous: no approval question was ever asked
  expect_length(chat$log, 1)
  expect_match(chat$log[1], "NEVER see")
})

test_that("without modelblueprint, validation is skipped cleanly", {
  testthat::local_mocked_bindings(mb_available = function() FALSE)
  chat <- FakeChat$new(list(
    list(
      calls = list(list(tool = "run_r_code", args = list(code = paste(
        "atlas_models <- list(m = lm(mpg ~ wt, data));",
        "atlas_leaderboard <- data.frame(name = 'm', metric = 'rmse', value = 3)")))),
      reply = "built"
    )
  ))
  s <- AtlasSession$new(mtcars, "mpg", chat = chat, dir = temp_dir())

  # the agent is never told about modelblueprint or its file-write exception
  expect_no_match(s$chat$get_system_prompt(), "modelblueprint")

  res <- s$build(verbose = FALSE, refine = FALSE)  # validate = TRUE (default)
  expect_length(chat$log, 1)                       # no validation prompt sent
  expect_s3_class(res$models$m, "lm")
})

test_that("build() refines the winner under the stopping rules", {
  dir <- temp_dir()
  chat <- FakeChat$new(list(
    list(
      calls = list(list(tool = "run_r_code", args = list(code = paste(
        "atlas_models <- list(glm1 = lm(mpg ~ wt, data));",
        "atlas_leaderboard <- data.frame(name = 'glm1', metric = 'rmse', value = 3)")))),
      reply = "built"
    ),
    list(
      calls = list(list(tool = "run_r_code", args = list(code = paste(
        "atlas_models$glm1_refined <- lm(mpg ~ wt + I(wt^2) + hp, data);",
        "atlas_leaderboard <- rbind(atlas_leaderboard,",
        "  data.frame(name = 'glm1_refined', metric = 'rmse', value = 2.6))")))),
      reply = "refined: added wt^2 and hp, stopped after 3 flat attempts"
    )
  ))
  s <- AtlasSession$new(mtcars, "mpg", chat = chat, dir = dir,
                        patience = 4, min_improve = 0.02)
  res <- s$build(verbose = FALSE, validate = FALSE)

  expect_length(chat$log, 2)
  expect_match(chat$log[2], "refine the winner")
  expect_match(chat$log[2], "feature selection and feature engineering")
  # the session's own stopping rules are restated with real numbers
  expect_match(chat$log[2], "4 consecutive attempts")
  expect_match(chat$log[2], "2% \\(relative\\)")
  expect_match(chat$log[2], "_refined")

  expect_s3_class(res$models$glm1_refined, "lm")
  expect_equal(nrow(res$leaderboard), 2)
})

test_that("constraints are re-verified after refinement", {
  chat <- FakeChat$new(list(
    list(  # build a compliant winner
      calls = list(list(tool = "run_r_code", args = list(code = paste(
        "atlas_models <- list(m = lm(mpg ~ wt, data));",
        "atlas_leaderboard <- data.frame(name = 'm', metric = 'rmse', value = 3)")))),
      reply = "built"
    ),
    list(  # refinement drops wt: violates the constraint
      calls = list(list(tool = "run_r_code", args = list(code =
        "atlas_models$m_refined <- lm(mpg ~ hp, data)"))),
      reply = "refined"
    ),
    list(  # repair round restores it
      calls = list(list(tool = "run_r_code", args = list(code =
        "atlas_models$m_refined <- lm(mpg ~ hp + wt, data)"))),
      reply = "fixed"
    )
  ))
  s <- AtlasSession$new(mtcars, "mpg",
                        constraints = list(uses_wt = con_uses("wt")),
                        chat = chat, dir = temp_dir())
  res <- s$build(verbose = FALSE, validate = FALSE)

  expect_length(chat$log, 3)
  expect_match(chat$log[3], "constraint 'uses_wt'")
  expect_match(chat$log[3], "m_refined")
  expect_true(all(res$constraints$passed))
})

test_that("add_monotone_constraint tool creates an enforced, persisted constraint", {
  dir <- temp_dir()
  s <- new_session(dir)
  tool <- s$chat$get_tools()$add_monotone_constraint

  expect_match(tool(variable = "nope", direction = "increasing"),
               "not a column")

  msg <- tool(variable = "wt", direction = "decreasing")
  expect_match(msg, "monotonically decreasing")

  s$env$atlas_models <- list(m = lm(mpg ~ wt, mtcars))
  df <- s$check()
  expect_equal(df$constraint, "mono_wt")
  expect_true(df$passed)

  # persisted, so it survives a resume
  expect_true("mono_wt" %in%
                names(readRDS(file.path(dir, "meta.rds"))$constraints))
})

test_that("verbose tell() streams narration, code, and output", {
  chat <- FakeChat$new(list(
    list(calls = list(list(tool = "run_r_code", args = list(code = "1 + 1"))),
         reply = "All done.")
  ))
  s <- new_session(chat = chat)
  shown <- paste(capture.output(reply <- s$tell("go", verbose = TRUE)),
                 collapse = "\n")

  expect_match(shown, "1 \\+ 1")        # the code block
  expect_match(shown, "#> \\[1\\] 2")   # its output
  expect_match(shown, "All done\\.")    # the narration
  expect_equal(reply, "All done.")
})
