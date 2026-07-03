# Session persistence: everything except the LLM call itself, which needs an
# API key and is exercised in the vignette / manually.
fake_chat <- function() {
  # a real chat object that never makes a request; key just satisfies the ctor
  if (Sys.getenv("ANTHROPIC_API_KEY") == "") {
    Sys.setenv(ANTHROPIC_API_KEY = "test-key-no-network")
  }
  ellmer::chat_anthropic()
}

new_session <- function(dir = withr_dir()) {
  AtlasSession$new(mtcars, "mpg", n_models = 2, goal = "keep it simple",
                   chat = fake_chat(), dir = dir)
}

withr_dir <- function() {
  dir <- file.path(tempdir(), paste0("atlas-", as.integer(stats::runif(1, 1, 1e9))))
  dir
}

test_that("initialize validates inputs", {
  expect_error(AtlasSession$new(mtcars, "not_a_col", chat = fake_chat(),
                                dir = withr_dir()),
               "not a column")
  expect_error(AtlasSession$new("not data", "mpg", chat = fake_chat(),
                                dir = withr_dir()))
})

test_that("session writes its inputs and checkpoints to the run dir", {
  dir <- withr_dir()
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

test_that("atlas_resume replays the code log and reconstructs the environment", {
  dir <- withr_dir()
  s <- new_session(dir)
  s$code <- c("set.seed(1)", "m <- lm(mpg ~ wt, data)",
              "atlas_models <- list(lm = m)",
              "atlas_leaderboard <- data.frame(name = 'lm', type = 'regression',
                 metric = 'rmse', value = 3, notes = 'baseline')")
  for (chunk in s$code) Atlas:::atlas_run_code(chunk, s$env)
  s$checkpoint()

  r <- atlas_resume(dir, chat = fake_chat())
  expect_equal(r$code, s$code)
  expect_s3_class(r$env$atlas_models$lm, "lm")
  expect_equal(coef(r$env$atlas_models$lm), coef(s$env$atlas_models$lm))
  expect_equal(r$env$atlas_leaderboard$name, "lm")
})

test_that("run_r_code tool logs, checkpoints, and prints readable blocks", {
  dir <- withr_dir()
  s <- new_session(dir)
  run_tool <- s$chat$get_tools()$run_r_code
  shown <- capture.output(res <- run_tool("  \n1 + 1\n"))
  expect_equal(res, "[1] 2")
  expect_equal(s$code, "1 + 1")
  expect_true(any(grepl("1 \\+ 1", shown)))
  expect_true(any(grepl("#> \\[1\\] 2", shown)))
  expect_true(file.exists(file.path(dir, "code.rds")))
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
