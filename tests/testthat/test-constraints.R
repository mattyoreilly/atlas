# Constraint machinery: definition, normalization, and verification.

test_that("constraint() validates its inputs", {
  expect_error(constraint(1))
  expect_error(constraint(c("two", "rules")))
  expect_error(constraint("ok", check = "not a function"))
  expect_s3_class(constraint("ok"), "atlas_constraint")
})

test_that("normalize_constraints accepts strings, constraints, and mixes", {
  n <- Atlas:::normalize_constraints
  expect_equal(n(NULL), list())
  one <- n("never use qsec")
  expect_named(one, "constraint_1")
  expect_s3_class(one[[1]], "atlas_constraint")

  mixed <- n(list(uses_wt = con_uses("wt"), "no leakage"))
  expect_named(mixed, c("uses_wt", "constraint_2"))
  expect_true(is.function(mixed$uses_wt$check))
  expect_null(mixed$constraint_2$check)

  # a bare constraint object needs no list()
  bare <- n(con_uses("wt"))
  expect_named(bare, "constraint_1")
  expect_true(is.function(bare$constraint_1$check))
})

test_that("con_uses detects used and unused variables", {
  m_with <- lm(mpg ~ wt + hp, mtcars)
  m_without <- lm(mpg ~ hp, mtcars)
  chk <- con_uses("wt")$check
  expect_true(chk(m_with, mtcars))
  expect_match(chk(m_without, mtcars), "does not use")
  expect_match(chk(m_with, mtcars[, "mpg", drop = FALSE]), "not in the data")
})

test_that("con_monotone detects monotone and non-monotone response", {
  m_lin <- lm(mpg ~ wt, mtcars)            # coef(wt) < 0: decreasing
  expect_true(con_monotone("wt", "decreasing")$check(m_lin, mtcars))
  expect_match(con_monotone("wt", "increasing")$check(m_lin, mtcars),
               "not monotonically increasing")

  u <- data.frame(x = seq(0, 10, 0.5))
  u$y <- (u$x - 5)^2                        # exactly U-shaped in x
  m_u <- lm(y ~ poly(x, 2), u)
  expect_match(con_monotone("x", "decreasing")$check(m_u, u),
               "not monotonically decreasing")
  expect_match(con_monotone("x", "increasing")$check(m_u, u),
               "not monotonically increasing")
})

test_that("verify_constraints reports per model, tolerates errors, keeps prompt-only rows", {
  cons <- Atlas:::normalize_constraints(list(
    uses_wt = con_uses("wt"),
    boom = constraint("always fails loudly",
                      check = function(model, data) stop("kaput")),
    note = "prompt-only rule"
  ))
  models <- list(good = lm(mpg ~ wt, mtcars), bad = lm(mpg ~ hp, mtcars))
  df <- Atlas:::verify_constraints(cons, models, mtcars)

  expect_equal(nrow(df), 5) # 2x2 checked + 1 prompt-only
  expect_true(df$passed[df$model == "good" & df$constraint == "uses_wt"])
  expect_false(df$passed[df$model == "bad" & df$constraint == "uses_wt"])
  expect_match(df$detail[df$constraint == "boom"][1], "check errored: kaput")
  expect_true(is.na(df$passed[df$constraint == "note"]))

  empty <- Atlas:::verify_constraints(list(), models, mtcars)
  expect_equal(nrow(empty), 0)

  # checked constraints but no models yet: nothing to verify
  no_models <- Atlas:::verify_constraints(
    Atlas:::normalize_constraints(list(uses_wt = con_uses("wt"))), NULL, mtcars)
  expect_equal(nrow(no_models), 0)
})

test_that("con_monotone copes with tiny data and unused variables", {
  m <- lm(mpg ~ wt, mtcars)
  expect_true(con_monotone("wt", "decreasing")$check(m, mtcars[1, ]))
  # unused variable: flat response is (non-strictly) monotone both ways
  expect_true(con_monotone("hp", "increasing")$check(m, mtcars))
  expect_true(con_monotone("hp", "decreasing")$check(m, mtcars))
})

test_that("atlas_leakage_screen flags near-perfect predictors only", {
  leaky <- mtcars
  leaky$mpg_copy <- leaky$mpg * 2 + 1        # deterministic function of target
  leaky$id <- as.factor(seq_len(nrow(leaky))) # high-cardinality: not assessable
  scr <- atlas_leakage_screen(leaky, "mpg")

  expect_true(scr$flagged[scr$variable == "mpg_copy"])
  expect_false(scr$flagged[scr$variable == "wt"])   # strong but honest: ~0.75
  expect_true(is.na(scr$r2[scr$variable == "id"]))
  expect_false(scr$flagged[scr$variable == "id"])
  expect_false("mpg" %in% scr$variable)

  # threshold is respected
  scr_loose <- atlas_leakage_screen(leaky, "mpg", threshold = 0.5)
  expect_true(scr_loose$flagged[scr_loose$variable == "wt"])
})

test_that("excluded columns are removed before the agent sees the data", {
  dir <- temp_dir()
  leaky <- mtcars
  leaky$post_hoc <- leaky$mpg + 1
  s <- AtlasSession$new(leaky, "mpg", exclude = c("post_hoc", "qsec"),
                        chat = real_chat(), dir = dir)

  expect_false(any(c("post_hoc", "qsec") %in% names(s$env$data)))
  expect_false("post_hoc" %in% names(readRDS(file.path(dir, "data.rds"))))
  expect_equal(readRDS(file.path(dir, "meta.rds"))$exclude,
               c("post_hoc", "qsec"))

  prompt <- Atlas:::atlas_task_prompt(s$env$data,
                                      readRDS(file.path(dir, "meta.rds")))
  expect_match(prompt, "excluded these columns")
  expect_match(prompt, "post_hoc, qsec")

  expect_error(AtlasSession$new(mtcars, "mpg", exclude = "mpg",
                                chat = real_chat(), dir = temp_dir()),
               "outcome cannot be excluded")
})

test_that("leakage flags reach the task prompt", {
  dir <- temp_dir()
  leaky <- mtcars
  leaky$mpg_copy <- leaky$mpg
  s <- AtlasSession$new(leaky, "mpg", chat = real_chat(), dir = dir)
  prompt <- Atlas:::atlas_task_prompt(s$env$data,
                                      readRDS(file.path(dir, "meta.rds")))
  expect_match(prompt, "leakage screen")
  expect_match(prompt, "mpg_copy")
  expect_match(prompt, "ask_user")
})

test_that("constraints_from_spec maps parsed specs to the right types", {
  spec <- data.frame(
    name = c("uses_wt", "mono_hp", "no_leak", "bad_var", "no_dir", NA),
    type = c("uses", "monotone", "other", "uses", "monotone", "other"),
    variable = c("wt", "hp", NA, "nonexistent", "wt", NA),
    direction = c(NA, "decreasing", NA, NA, NA, NA),
    description = paste("rule", 1:6)
  )
  cons <- Atlas:::constraints_from_spec(spec, mtcars)

  expect_true(is.function(cons$uses_wt$check))
  expect_true(is.function(cons$mono_hp$check))
  expect_null(cons$no_leak$check)      # 'other' -> prompt-only
  expect_null(cons$bad_var$check)      # unknown column -> falls back
  expect_null(cons$no_dir$check)       # monotone without direction -> falls back
  expect_named(cons, c("uses_wt", "mono_hp", "no_leak", "bad_var", "no_dir",
                       "constraint_6"))

  # the machine checks it built actually work
  expect_true(cons$uses_wt$check(lm(mpg ~ wt, mtcars), mtcars))
  expect_match(cons$mono_hp$check(lm(mpg ~ I(-hp) + I(hp^2), mtcars), mtcars),
               "not monotonically")

  expect_equal(Atlas:::constraints_from_spec(spec[0, ], mtcars), list())
  expect_output(print(cons$uses_wt), "machine-checked")
  expect_output(print(cons$no_leak), "prompt-only")
})

test_that("session wires constraints into prompts, tools, and results", {
  dir <- temp_dir()
  s <- AtlasSession$new(mtcars, "mpg", constraints = list(uses_wt = con_uses("wt")),
                        chat = real_chat(), dir = dir)

  expect_match(s$chat$get_system_prompt(), "check_constraints")
  expect_match(Atlas:::atlas_task_prompt(mtcars, readRDS(file.path(dir, "meta.rds"))),
               "Hard constraints")

  s$env$atlas_models <- list(bad = lm(mpg ~ hp, mtcars))
  df <- s$check()
  expect_false(df$passed)

  tool_out <- s$chat$get_tools()$check_constraints()
  expect_match(tool_out, "uses_wt")

  s$env$atlas_leaderboard <- data.frame(name = "bad", metric = "rmse", value = 4)
  res <- s$results()
  expect_output(print(res), "does not use")  # failing detail is shown

  # constraints survive a resume
  s$checkpoint()
  r <- atlas_resume(dir, chat = real_chat())
  expect_match(r$chat$get_system_prompt(), "check_constraints")
  expect_true("check_constraints" %in% names(r$chat$get_tools()))
})
