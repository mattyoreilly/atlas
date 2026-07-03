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
#' @param n_models How many candidate models to build.
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
#' @param chat An ellmer chat object. Defaults to `ellmer::chat_anthropic()`
#'   (requires `ANTHROPIC_API_KEY`). Any tool-capable ellmer provider works.
#' @param dir Run directory for checkpoints and artifacts. Defaults to
#'   `.atlas/<timestamp>`.
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
#'                uses_wt   = con_uses("wt"),
#'                mono_hp   = con_monotone("hp", "decreasing"),
#'                no_leak   = "qsec is measured after the fact; never use it"
#'              ))
#' res$constraints            # compliance table: model x constraint
#' res                        # leaderboard + report
#' res$models$lm              # a fitted model, ready for predict()
#' cat(res$code, sep = "\n\n")
#' res$session$tell("why did the random forest win?")
#' }
#' @export
atlas <- function(data, outcome, n_models = 3, goal = NULL,
                  constraints = NULL, chat = NULL, dir = NULL,
                  verbose = TRUE, max_fix_rounds = 2) {
  session <- AtlasSession$new(data, outcome, n_models = n_models, goal = goal,
                              constraints = constraints, chat = chat, dir = dir)
  session$build(verbose = verbose, max_fix_rounds = max_fix_rounds)
  session$results()
}

#' @export
print.atlas <- function(x, ...) {
  cat("<atlas>", x$dir, "\n")
  if (is.data.frame(x$leaderboard)) {
    cat("\n")
    print(x$leaderboard)
  }
  cst <- x$constraints
  if (is.data.frame(cst) && nrow(cst) > 0) {
    bad <- cst[!is.na(cst$passed) & !cst$passed, , drop = FALSE]
    if (nrow(bad) > 0) {
      cat("\nUNMET CONSTRAINTS:\n")
      print(bad, row.names = FALSE)
    } else {
      cat("\nAll machine-checked constraints satisfied.\n")
    }
  }
  if (!is.null(x$report)) cat("\n", x$report, "\n", sep = "")
  invisible(x)
}
