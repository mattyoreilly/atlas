# The app's offline-testable parts. The full browser flow is manual.

test_that("on_ask handler overrides the console for agent questions", {
  seen <- NULL
  s <- new_session(on_ask = function(q) {
    seen <<- q
    "approved, go ahead"
  })
  ans <- s$chat$get_tools()$ask_user(question = "Is the plan OK?")
  expect_equal(ans, "approved, go ahead")
  expect_equal(seen, "Is the plan OK?")
})

test_that("app UI builds and has the key inputs", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  ui <- Atlas:::atlas_app_ui()
  html <- as.character(ui)
  for (id in c("file", "outcome", "n_models", "goal", "rules", "build",
               "patience", "min_improve", "tabs", "outdir", "browse_dir",
               "interject_ui")) {
    expect_match(html, paste0("\"", id, "\""), fixed = FALSE)
  }
})

test_that("atlas_load_results re-verifies constraints from a run directory", {
  dir <- temp_dir()
  s <- AtlasSession$new(mtcars, "mpg",
                        constraints = list(uses_wt = con_uses("wt")),
                        chat = real_chat(), dir = dir)
  expect_null(Atlas:::atlas_load_results(dir))  # no models saved yet

  saveRDS(list(m = lm(mpg ~ wt, mtcars)), file.path(dir, "models.rds"))
  df <- Atlas:::atlas_load_results(dir)
  expect_true(df$passed)
  expect_equal(df$constraint, "uses_wt")
})

test_that("markdown display mode emits fenced blocks for the app log", {
  s <- new_session(display = "markdown")
  shown <- paste(capture.output(res <- s$chat$get_tools()$run_r_code("1 + 1")),
                 collapse = "\n")
  expect_match(shown, "```r\n1 \\+ 1\n```", fixed = FALSE)
  expect_match(shown, "```\n#> \\[1\\] 2\n```", fixed = FALSE)
  expect_equal(res, "[1] 2")           # what the agent sees is unchanged
  expect_no_match(shown, "──")         # no terminal rules in the app log
})

test_that("app worker calls Atlas functions only via ::", {
  # callr transports the worker without its namespace, so unqualified Atlas
  # calls fail at runtime in the background process
  body_txt <- paste(deparse(body(Atlas:::atlas_app_worker)), collapse = "\n")
  for (fn in c("extract_constraints\\(", "AtlasSession\\$", "atlas_run_code\\(",
               "constraint\\(", "atlas\\(", "atlas_resume\\(")) {
    expect_false(grepl(paste0("(?<!:)\\b", fn), body_txt, perl = TRUE),
                 label = paste("unqualified call to", fn))
  }
})

test_that("markdown tables actually render to HTML tables", {
  skip_if_not_installed("commonmark")
  md <- Atlas:::md_table(data.frame(name = "mpg", value = 0))
  # regression: without extensions = TRUE, pipe tables render as plain text
  expect_match(commonmark::markdown_html(md, extensions = TRUE), "<table>")
})

test_that("constraint format/print marks checked vs prompt-only", {
  expect_match(format(con_uses("wt")), "^\\[machine-checked\\]")
  expect_match(format(constraint("no leakage")), "^\\[prompt-only\\]")
})
