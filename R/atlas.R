#' Build models automatically with an LLM agent
#'
#' One-call convenience wrapper around [AtlasSession]: hands your data to an
#' agentic LLM that explores it, proposes a plan for your approval, fits and
#' evaluates `n_models` candidate models, and returns the fitted models with a
#' leaderboard and a report of how each was built. Progress streams to the
#' console; the agent pauses for your input when it needs a decision. All
#' state is checkpointed to a run directory, so an interrupted run can be
#' picked up with [atlas_resume()].
#'
#' @param data A data.frame.
#' @param outcome Name of the outcome column (string).
#' @param n_models Maximum number of candidate models to build; the agent
#'   stops earlier when the stopping rules trigger (see `patience` and
#'   `min_improve`).
#' @param patience Stopping rule: give up on an iteration (adding candidate
#'   models, or a refinement loop like "keep improving the features") after
#'   this many consecutive attempts without improvement.
#' @param min_improve Stopping rule: an attempt only counts as an improvement
#'   if it beats the best validation metric so far by at least this relative
#'   fraction, between 0 and 1 — e.g. `0.05` for 5%.
#' @param exclude Columns the models must not use — because they won't be
#'   available at prediction time in deployment, or they leak the outcome.
#'   They are removed from the data before the agent sees it. Predictors that
#'   survive are additionally screened with [atlas_leakage_screen()], and the
#'   agent is told to confirm anything suspicious with you before using it.
#' @param goal Optional extra instructions (your own system-prompt additions),
#'   e.g. "prioritise interpretability" or "don't use tree-based models".
#' @param constraints Domain knowledge as hard requirements: a list of plain
#'   strings (enforced via instructions) and/or [constraint()] objects with a
#'   `check` function (verified against every final model; violations are
#'   sent back to the agent to fix, up to `max_fix_rounds` times). Helpers:
#'   [con_uses()] (a variable must be used), [con_monotone()] (predictions
#'   monotonic in a variable). Compliance is reported in the `constraints`
#'   element of the result.
#' @param max_fix_rounds How many automatic constraint-repair rounds to allow
#'   after the initial build.
#' @param refine After the winning algorithm is found (and constraints pass),
#'   keep iterating on its feature selection and engineering — one change per
#'   attempt, same validation scheme — until the stopping rules trigger
#'   (`patience` consecutive attempts without a relative gain of at least
#'   `min_improve`). The refined model lands in the results as
#'   `<winner>_refined`, alongside the original.
#' @param validate Produce reviewable validation output for the winning model
#'   (gain, calibration, grouped residuals, one-ways, PDPs) as interactive
#'   HTML files in the run directory, via the `modelblueprint` package.
#'   Silently skipped when `modelblueprint` isn't installed.
#' @param chat An ellmer chat object. Defaults to `ellmer::chat_anthropic()`
#'   (requires `ANTHROPIC_API_KEY`). Any tool-capable ellmer provider works.
#' @param dir Run directory for checkpoints and all artifacts (reports,
#'   validation plots, model bundles). Defaults to a timestamped folder under
#'   `getOption("atlas.dir", ".atlas")`; set
#'   `options(atlas.dir = "~/atlas-runs")` in your `.Rprofile` to send every
#'   run somewhere of your choosing, or pass `dir` explicitly.
#' @param verbose Stream the agent's narration to the console.
#' @return An object of class `atlas`: list with `models` (named list of
#'   fitted models), `leaderboard` (data.frame of validation metrics),
#'   `report` (markdown, how each model was built), `code` (every code chunk
#'   the agent ran), `dir`, and `session` (the live [AtlasSession], for
#'   follow-ups via `$tell()`).
#' @examples
#' \dontrun{
#' res <- atlas(mtcars, "mpg", n_models = 3,
#'              goal = "prioritise interpretability",
#'              constraints = list(
#'                uses_wt = con_uses("wt"),
#'                mono_hp = con_monotone("hp", "decreasing"),
#'                no_leak = "qsec is measured after the fact; never use it"
#'              ))
#' res                          # leaderboard, constraint status, report
#' res$constraints              # compliance table: model x constraint
#' predict(res$models[[1]], head(mtcars))
#' cat(res$code, sep = "\n\n")  # the full script the agent ran
#' res$session$tell("why did the winning model win?")
#' }
#' @export
atlas <- function(data, outcome, n_models = 3, goal = NULL,
                  constraints = NULL, chat = NULL, dir = NULL,
                  verbose = TRUE, max_fix_rounds = 2,
                  patience = 3, min_improve = 0.05, refine = TRUE,
                  validate = TRUE, exclude = NULL) {
  session <- AtlasSession$new(data, outcome, n_models = n_models, goal = goal,
                              constraints = constraints, chat = chat, dir = dir,
                              patience = patience, min_improve = min_improve,
                              exclude = exclude)
  session$build(verbose = verbose, max_fix_rounds = max_fix_rounds,
                refine = refine, validate = validate)
  session$results()
}

#' @export
print.atlas <- function(x, ...) {
  cli::cli_rule(left = "atlas")
  cat("run directory:", x$dir, "\n")
  if (is.data.frame(x$leaderboard) && nrow(x$leaderboard) > 0) {
    cat("\n")
    cli::cli_rule(left = "leaderboard")
    print_clean(x$leaderboard)
  }
  cst <- x$constraints
  if (is.data.frame(cst) && nrow(cst) > 0) {
    bad <- cst[!is.na(cst$passed) & !cst$passed, , drop = FALSE]
    cat("\n")
    if (nrow(bad) > 0) {
      cli::cli_alert_danger("Unmet constraints:")
      print_clean(bad)
    } else {
      cli::cli_alert_success("All machine-checked constraints satisfied.")
    }
  }
  if (!is.null(x$report)) {
    cat("\n")
    cli::cli_rule(left = "report")
    cat(x$report, "\n")
  }
  invisible(x)
}

# Console table: rounded numerics, no row names.
print_clean <- function(df, digits = 4) {
  df <- as.data.frame(df)
  num <- vapply(df, is.numeric, logical(1))
  df[num] <- lapply(df[num], signif, digits)
  print(df, row.names = FALSE, right = FALSE)
  invisible(df)
}

# data.frame -> markdown pipe table (rounded numerics, NAs blank), for
# streams that get rendered as markdown (the app log, agent tool results).
md_table <- function(df, digits = 4) {
  cells <- lapply(df, function(col) {
    if (is.numeric(col)) col <- signif(col, digits)
    out <- as.character(col)
    out[is.na(out)] <- ""
    gsub("|", "\\|", out, fixed = TRUE)
  })
  header <- paste0("| ", paste(names(df), collapse = " | "), " |")
  sep <- paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|")
  rows <- do.call(paste, c(cells, list(sep = " | ")))
  paste(c(header, sep, if (length(rows)) paste0("| ", rows, " |")),
        collapse = "\n")
}
