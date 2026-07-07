# Snapshot the text the LLM and the user actually see, so accidental prompt
# and formatting changes show up in review.

test_that("system prompt is stable", {
  expect_snapshot(cat(atlas:::atlas_system_prompt(3)))
  expect_snapshot(cat(atlas:::atlas_system_prompt(2, has_constraints = TRUE)))
})

test_that("task prompt is stable", {
  meta <- list(outcome = "mpg", n_models = 2, goal = "keep it simple",
               constraints = atlas:::normalize_constraints(
                 list(uses_wt = con_uses("wt"), "no leakage")))
  expect_snapshot(cat(atlas:::atlas_task_prompt(mtcars, meta)))
})

test_that("refine prompt is stable", {
  meta <- list(stopping_rounds = 3, stopping_tolerance = 0.05,
               constraints = atlas:::normalize_constraints("no leakage"))
  expect_snapshot(cat(atlas:::atlas_refine_prompt(meta)))
})

test_that("fix prompt is stable", {
  fails <- data.frame(
    model = c("m1", "m2"), constraint = c("uses_wt", "mono_hp"),
    passed = FALSE, detail = c("predictions unchanged when `wt` is scrambled", ""))
  expect_snapshot(cat(atlas:::atlas_fix_prompt(fails)))
})

test_that("print.atlas output is stable", {
  res <- structure(
    list(models = list(),
         leaderboard = data.frame(name = "m1", metric = "rmse", value = 3.2),
         constraints = data.frame(model = "m1", constraint = "uses_wt",
                                  passed = TRUE, detail = ""),
         report = "The winner is m1.", code = character(),
         dir = "<run-dir>", session = NULL),
    class = "atlas")
  expect_snapshot(print(res))

  res$constraints$passed <- FALSE
  res$constraints$detail <- "the model does not use it"
  expect_snapshot(print(res))
})

test_that("md_table renders tidy markdown tables", {
  df <- data.frame(model = c("a", "b"), value = c(3.14159, NA),
                   note = c("with | pipe", "ok"))
  expect_snapshot(cat(atlas:::md_table(df)))
  # zero rows: header and separator only
  expect_equal(atlas:::md_table(df[0, ]),
               "| model | value | note |\n|---|---|---|")
})
