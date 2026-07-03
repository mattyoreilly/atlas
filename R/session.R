#' A persistent, resumable model-building session
#'
#' An `AtlasSession` wraps an LLM agent, an R working environment holding your
#' data, and a run directory on disk. The agent builds models by executing R
#' code; every code chunk and conversation turn is checkpointed to the run
#' directory, so a session survives crashes and R restarts (see
#' [atlas_resume()]). The agent pauses and asks for your approval or input via
#' the console when it needs a decision (interactive sessions only).
#'
#' @section Run directory contents:
#' * `data.rds`, `meta.rds` — inputs, so the session can be rebuilt cold
#' * `code.R` / `code.rds` — every code chunk the agent executed
#' * `turns.rds` — the full conversation
#' * `report.md`, `leaderboard.csv`, `models.rds` — final artifacts
#'
#' @examples
#' \dontrun{
#' s <- AtlasSession$new(mtcars, outcome = "mpg", n_models = 3)
#' res <- s$build()          # agent works, asking for approval as needed
#' res                       # leaderboard + per-model report
#' s$tell("try a model with only 3 predictors as a 4th candidate")
#'
#' # later, in a new R session:
#' s <- atlas_resume(".atlas/20260703-141500")
#' }
#' @importFrom R6 R6Class
#' @importFrom ellmer tool type_string
#' @importFrom cli cli_rule
#' @importFrom coro is_exhausted
#' @export
AtlasSession <- R6::R6Class("AtlasSession",
  public = list(
    #' @field chat The underlying ellmer chat object.
    chat = NULL,
    #' @field env Environment the agent's code runs in (`data` lives here).
    env = NULL,
    #' @field dir Run directory used for checkpoints and artifacts.
    dir = NULL,
    #' @field code Character vector of every code chunk executed so far.
    code = character(),

    #' @description Create a session.
    #' @param data A data.frame.
    #' @param outcome Name of the outcome column (string).
    #' @param n_models How many final candidate models to build.
    #' @param goal Optional extra instructions for the agent, e.g.
    #'   "prioritise interpretability" or a full custom brief.
    #' @param constraints Domain knowledge as hard requirements: a list of
    #'   strings and/or [constraint()] objects (see also [con_uses()],
    #'   [con_monotone()]). Machine-checked constraints are verified against
    #'   every final model.
    #' @param chat An ellmer chat object. Defaults to
    #'   `ellmer::chat_anthropic()`. Any ellmer provider works.
    #' @param dir Run directory. Defaults to `.atlas/<timestamp>`.
    initialize = function(data, outcome, n_models = 3, goal = NULL,
                          constraints = NULL, chat = NULL, dir = NULL) {
      stopifnot(is.data.frame(data), is.character(outcome), length(outcome) == 1)
      if (!outcome %in% names(data)) {
        stop("outcome '", outcome, "' is not a column of `data`", call. = FALSE)
      }
      private$meta <- list(outcome = outcome, n_models = n_models, goal = goal,
                           constraints = normalize_constraints(constraints))
      self$dir <- dir %||% file.path(".atlas", format(Sys.time(), "%Y%m%d-%H%M%S"))
      dir.create(self$dir, recursive = TRUE, showWarnings = FALSE)
      saveRDS(data, file.path(self$dir, "data.rds"))
      saveRDS(private$meta, file.path(self$dir, "meta.rds"))

      self$env <- new.env(parent = globalenv())
      self$env$data <- data
      self$chat <- chat %||% ellmer::chat_anthropic()
      self$chat$set_system_prompt(
        atlas_system_prompt(n_models, length(private$meta$constraints) > 0))
      private$register_tools()
    },

    #' @description Run the full model-building loop. Streams the agent's
    #'   narration and asks for approval/input in the console when needed.
    #'   After the build, machine-checked constraints are verified against
    #'   every final model; violations are sent back to the agent to fix, up
    #'   to `max_fix_rounds` times.
    #' @param verbose Show the agent's narration, code, and output live.
    #' @param max_fix_rounds How many constraint-repair rounds to allow.
    #' @return An `atlas` results object (invisibly); see `$results()`.
    build = function(verbose = TRUE, max_fix_rounds = 2) {
      self$tell(atlas_task_prompt(self$env$data, private$meta),
                verbose = verbose)
      for (round in seq_len(max_fix_rounds)) {
        fails <- self$check()
        fails <- fails[!is.na(fails$passed) & !fails$passed, , drop = FALSE]
        if (nrow(fails) == 0) break
        self$tell(atlas_fix_prompt(fails), verbose = verbose)
      }
      invisible(self$results())
    },

    #' @description Verify all machine-checked constraints against the
    #'   current `atlas_models`.
    #' @return A data.frame with one row per model x constraint: `model`,
    #'   `constraint`, `passed` (`NA` for prompt-only constraints), `detail`.
    check = function() {
      verify_constraints(private$meta$constraints,
                         self$env$atlas_models, self$env$data)
    },

    #' @description Send a follow-up instruction or question to the agent in
    #'   the same context ("why did you drop cyl?", "add a 4th model", ...).
    #' @param text What to say to the agent.
    #' @param verbose As in `$build()`.
    #' @return The agent's reply (invisibly).
    tell = function(text, verbose = TRUE) {
      private$verbose <- verbose
      if (verbose) {
        # stream narration as plain text; tools print their own blocks
        stream <- self$chat$stream(text)
        pieces <- character()
        repeat {
          chunk <- stream()
          if (coro::is_exhausted(chunk)) break
          cat(chunk)
          pieces[[length(pieces) + 1]] <- chunk
        }
        cat("\n")
        reply <- paste(pieces, collapse = "")
      } else {
        reply <- self$chat$chat(text, echo = "none")
      }
      self$checkpoint()
      private$write_artifacts(reply)
      invisible(reply)
    },

    #' @description Collect results: the fitted models, the leaderboard, the
    #'   report, and the full code trail.
    #' @return An object of class `atlas`: list with `models` (named list of
    #'   fitted models), `leaderboard` (data.frame of validation metrics),
    #'   `report` (markdown), `code`, `dir`, and `session` (this object).
    results = function() {
      if (is.null(self$env$atlas_models)) {
        warning("agent has not produced `atlas_models` yet; ",
                "run $build() or inspect $chat", call. = FALSE)
      }
      structure(
        list(models = self$env$atlas_models,
             leaderboard = self$env$atlas_leaderboard,
             constraints = self$check(),
             report = private$last_report, code = self$code,
             dir = self$dir, session = self),
        class = "atlas"
      )
    },

    #' @description Write the current code log and conversation to the run
    #'   directory. Called automatically after every tool call and reply.
    checkpoint = function() {
      saveRDS(self$code, file.path(self$dir, "code.rds"))
      writeLines(paste(self$code, collapse = "\n\n"),
                 file.path(self$dir, "code.R"))
      saveRDS(self$chat$get_turns(), file.path(self$dir, "turns.rds"))
      invisible(self)
    },

    #' @description Print a short status line.
    #' @param ... Ignored.
    print = function(...) {
      cat("<AtlasSession>", self$dir, "-",
          length(self$code), "code chunks run,",
          if (is.null(self$env$atlas_models)) "no models yet"
          else paste(length(self$env$atlas_models), "models built"), "\n")
      invisible(self)
    }
  ),

  private = list(
    meta = NULL,
    last_report = NULL,
    verbose = TRUE,

    register_tools = function() {
      self$chat$register_tool(ellmer::tool(
        function(code) {
          code <- trimws(code)
          self$code[[length(self$code) + 1]] <- code
          if (private$verbose) {
            cat("\n")
            cli::cli_rule(left = "R")
            cat(code, "\n", sep = "")
          }
          out <- atlas_run_code(code, self$env)
          self$checkpoint()
          if (private$verbose) {
            if (!identical(out, "(no output)")) {
              cat(cli::col_grey(paste0("#> ", gsub("\n", "\n#> ", out))),
                  "\n", sep = "")
            }
            cli::cli_rule()
            cat("\n")
          }
          out
        },
        name = "run_r_code",
        description = paste(
          "Execute R code in a persistent session. The training data is",
          "available as `data`. Variables persist between calls. Returns",
          "printed output (truncated if long) or the error message."
        ),
        arguments = list(code = ellmer::type_string("R code to execute"))
      ))
      self$chat$register_tool(ellmer::tool(
        function(question) {
          if (interactive()) {
            # cat the question first: readline() truncates long prompts
            cat("\n")
            cli::cli_rule(left = "atlas needs your input")
            cat(question, "\n")
            readline("> ")
          } else {
            paste("The user is not available (non-interactive session).",
                  "Proceed with your best judgment and record the decision",
                  "in your final report.")
          }
        },
        name = "ask_user",
        description = paste(
          "Ask the user a question and wait for their answer. Use it to get",
          "the modeling plan approved and whenever a decision genuinely needs",
          "user input. Ask one clear question at a time."
        ),
        arguments = list(question = ellmer::type_string("The question to ask"))
      ))
      if (length(private$meta$constraints) > 0) {
        self$chat$register_tool(ellmer::tool(
          function() {
            df <- self$check()
            if (nrow(df) == 0) {
              return("No models found. Create `atlas_models` first, then re-run this tool.")
            }
            if (private$verbose) {
              cat("\n")
              cli::cli_rule(left = "constraint check")
              print(df, row.names = FALSE)
              cli::cli_rule()
              cat("\n")
            }
            paste(utils::capture.output(print(df, row.names = FALSE)),
                  collapse = "\n")
          },
          name = "check_constraints",
          description = paste(
            "Verify every machine-checked constraint against the models in",
            "`atlas_models`. Run this after creating `atlas_models` and fix",
            "any failures before finishing."
          )
        ))
      }
    },

    write_artifacts = function(reply) {
      private$last_report <- reply
      writeLines(reply, file.path(self$dir, "report.md"))
      if (!is.null(self$env$atlas_models)) {
        saveRDS(self$env$atlas_models, file.path(self$dir, "models.rds"))
      }
      lb <- self$env$atlas_leaderboard
      if (is.data.frame(lb)) {
        utils::write.csv(lb, file.path(self$dir, "leaderboard.csv"),
                         row.names = FALSE)
      }
    }
  )
)

#' Resume a session from its run directory
#'
#' Rebuilds an [AtlasSession] after a crash or R restart: reloads the data,
#' replays every recorded code chunk to reconstruct the working environment
#' (models included), and restores the conversation so the agent remembers
#' everything it did.
#'
#' @param dir A run directory created by a previous session.
#' @param chat Optionally a fresh ellmer chat object (must be tool-capable);
#'   defaults to `ellmer::chat_anthropic()`.
#' @return An [AtlasSession].
#' @examples
#' \dontrun{
#' s <- atlas_resume(".atlas/20260703-141500")
#' s$tell("continue where you left off")
#' }
#' @export
atlas_resume <- function(dir, chat = NULL) {
  meta <- readRDS(file.path(dir, "meta.rds"))
  data <- readRDS(file.path(dir, "data.rds"))
  s <- AtlasSession$new(data, meta$outcome, n_models = meta$n_models,
                        goal = meta$goal, constraints = meta$constraints,
                        chat = chat, dir = dir)
  code_path <- file.path(dir, "code.rds")
  if (file.exists(code_path)) {
    s$code <- readRDS(code_path)
    # ponytail: environments aren't reliably serializable; replaying the code
    # log with the original data is exact reconstruction (agent code is seeded)
    for (chunk in s$code) atlas_run_code(chunk, s$env)
  }
  turns_path <- file.path(dir, "turns.rds")
  if (file.exists(turns_path)) s$chat$set_turns(readRDS(turns_path))
  s
}

atlas_system_prompt <- function(n_models, has_constraints = FALSE) {
  paste(
    "You are Atlas, an expert R statistician and ML engineer. You build models",
    "by writing R code and running it with the run_r_code tool. You can ask",
    "the user questions with the ask_user tool.",
    "",
    sprintf("Your job: build %d distinct candidate models for the stated outcome.", n_models),
    "",
    "Workflow:",
    "1. Explore the data: dimensions, types, missingness, outcome distribution.",
    "   Narrate what you find in 1-2 sentences.",
    "2. Propose a plan: task type (regression/classification), validation",
    "   scheme (holdout or CV, fixed seed), and the candidate model families.",
    "   Get the plan approved with ask_user before fitting anything.",
    "3. Fit and evaluate each candidate on held-out data. After each one,",
    "   narrate one line: model name, metric, value.",
    "4. Refit each candidate on all rows for the final versions.",
    "5. Create in the R session:",
    "   - `atlas_models`: named list of the final fitted models",
    "   - `atlas_leaderboard`: data.frame(name, type, metric, value, notes),",
    "     sorted best first, from the held-out evaluation",
    "6. End with a markdown report: data summary; one section per model",
    "   covering how it was built (preprocessing, features, tuning) and its",
    "   validation performance; a recommendation of which model to use.",
    "",
    "Rules:",
    "- Never call install.packages(), read/write files, or access the network.",
    "- Prefer base R; check optional packages with requireNamespace() and fall",
    "  back gracefully if missing.",
    "- Keep each code chunk small; inspect output before continuing.",
    "- Use ask_user when a decision genuinely needs the user; otherwise proceed.",
    if (has_constraints) paste(
      "- The task lists hard constraints. Every final model must satisfy all",
      "\n  of them. Design for them from the start (e.g. sign-constrained or",
      "\n  monotone model forms), don't bolt them on afterwards.",
      "\n- Machine checks require `predict(model, newdata)` to work on a",
      "\n  data.frame like `data`; make sure every model in `atlas_models`",
      "\n  supports that. After creating `atlas_models`, run the",
      "\n  check_constraints tool and fix any failures before finishing."),
    sep = "\n"
  )
}

atlas_task_prompt <- function(data, meta) {
  profile <- utils::capture.output(utils::str(data, list.len = 50))
  paste(
    sprintf("Build %d models predicting `%s` from the other columns.",
            meta$n_models, meta$outcome),
    sprintf("The data.frame `data` has %d rows and %d columns:",
            nrow(data), ncol(data)),
    paste(profile, collapse = "\n"),
    if (length(meta$constraints) > 0) paste0(
      "Hard constraints - every final model must satisfy ALL of these:\n",
      paste(sprintf("%d. [%s] %s%s",
                    seq_along(meta$constraints), names(meta$constraints),
                    vapply(meta$constraints, `[[`, "", "description"),
                    ifelse(vapply(meta$constraints,
                                  function(ci) is.null(ci$check), logical(1)),
                           "", " (machine-checked)")),
            collapse = "\n")),
    if (!is.null(meta$goal)) paste("Additional instructions:", meta$goal),
    sep = "\n\n"
  )
}

atlas_fix_prompt <- function(fails) {
  paste0(
    "Automated constraint verification found violations:\n",
    paste(sprintf("- model '%s', constraint '%s': %s",
                  fails$model, fails$constraint,
                  ifelse(fails$detail == "", "failed", fails$detail)),
          collapse = "\n"),
    "\n\nFix the violating models (refit them so the constraints hold - ",
    "change the model form if needed), update `atlas_models` and ",
    "`atlas_leaderboard`, verify with check_constraints, and briefly report ",
    "what you changed."
  )
}

# Execute one code chunk in `env`, returning printed output or the error.
atlas_run_code <- function(code, env, max_chars = 8000) {
  out <- tryCatch(
    utils::capture.output(eval_chunk(code, env)),
    error = function(e) paste("Error:", conditionMessage(e)),
    warning = function(w) paste("Warning:", conditionMessage(w))
  )
  out <- paste(out, collapse = "\n")
  if (out == "") out <- "(no output)"
  if (nchar(out) > max_chars) {
    out <- paste0(substr(out, 1, max_chars), "\n... [truncated]")
  }
  out
}

# Evaluate all expressions, auto-printing visible results like the console.
eval_chunk <- function(code, env) {
  for (expr in parse(text = code)) {
    res <- withVisible(eval(expr, env))
    if (res$visible) print(res$value)
  }
  invisible(NULL)
}
