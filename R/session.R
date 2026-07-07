#' A persistent, resumable model-building session
#'
#' An `atlas_session` wraps an LLM agent, an R working environment holding your
#' data, and a run directory on disk. The agent builds models by executing R
#' code; every code chunk and conversation turn is checkpointed to the run
#' directory, so a session survives crashes and R restarts (see
#' [atlas_resume()]). The agent pauses and asks for your approval or input via
#' the console when it needs a decision (interactive sessions only).
#'
#' @section Run directory contents:
#' * `data.rds`, `meta.rds` - inputs, so the session can be rebuilt cold
#' * `code.R` / `code.rds` - every code chunk the agent executed
#' * `turns.rds` - the full conversation
#' * `report.md`, `leaderboard.csv`, `models.rds` - final artifacts
#'
#' @examples
#' \dontrun{
#' s <- atlas_session$new(mtcars, outcome = "mpg", n_models = 3)
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
atlas_session <- R6::R6Class("atlas_session",
  public = list(
    #' @field chat The underlying ellmer chat object.
    chat = NULL,
    #' @field env Environment the agent's code runs in (`data` lives here).
    env = NULL,
    #' @field dir Run directory used for checkpoints and artifacts.
    dir = NULL,
    #' @field code Character vector of every code chunk executed so far.
    code = character(),
    #' @field test_data Held-out test rows (when `test_prop > 0`); never
    #'   placed in the agent's environment.
    test_data = NULL,
    #' @field tally Live experiment tally: one row per recorded attempt
    #'   (`attempt`, `name`, `metric`, `value`, `best`, `verdict`), kept by
    #'   atlas from the agent's `record_attempt` calls and persisted to
    #'   `tally.csv` in the run directory.
    tally = NULL,

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
    #' @param dir Run directory for checkpoints and all output (reports,
    #'   validation plots, model bundles). Defaults to a timestamped folder
    #'   under `getOption("atlas.dir", ".atlas")` - set
    #'   `options(atlas.dir = "~/atlas-runs")` once to send every run to a
    #'   location of your choosing, or pass `dir` explicitly per run.
    #' @param on_ask Optional handler for the agent's questions:
    #'   `function(question)` returning the user's answer as a string. When
    #'   `NULL` (default), questions are asked in the console (interactive
    #'   sessions) or answered with "use your best judgment" (scripts). Used
    #'   by [atlas_app()] to route questions to the browser.
    #' @param display How verbose progress is formatted: `"console"` (cli
    #'   rules and colours) or `"markdown"` (fenced code blocks, for
    #'   front-ends that render the stream as markdown, like [atlas_app()]).
    #' @param stopping_rounds Stopping rule: give up on an iteration (adding
    #'   candidates, or a refinement loop) after this many consecutive
    #'   attempts without improvement.
    #' @param stopping_tolerance Stopping rule: an attempt only counts as an
    #'   improvement if it beats the best validation metric so far by at
    #'   least this relative fraction, between 0 and 1 (e.g. `0.05` for 5%).
    #' @param exclude Columns the models must not use (not available at
    #'   prediction time, or leakage). They are removed from the data before
    #'   the agent ever sees it - the strongest possible guarantee.
    #' @param interject Optional `function()` polled after every tool call.
    #'   Return a string to interrupt the agent with a message mid-build (it
    #'   is delivered with its next tool result, marked as highest priority);
    #'   return `NULL` when there is nothing to say. Used by [atlas_app()]'s
    #'   "Send now" box; front-ends typically read the message from a file or
    #'   queue.
    #' @param autonomous Run without a human: the agent states its plan and
    #'   proceeds instead of asking for approval, and never calls `ask_user`.
    #' @param test_prop Proportion of rows (0 to <1) to hold out as a final
    #'   test set **the agent never sees**. Final models are evaluated on it
    #'   by Atlas itself after the run (`$results()$test_leaderboard`), so
    #'   the comparison can't be gamed by overfitting the agent's own
    #'   validation scheme. `0` (default) disables the split.
    #' @param compact_at Token budget for the conversation. When the context
    #'   grows past this many input tokens, it is compacted before the next
    #'   message: the transcript is archived to the run directory, the
    #'   window is cleared, and the agent is re-oriented with a briefing
    #'   built from the session state (no extra LLM call). Long runs stay
    #'   inside the model's context window and stop paying to re-read their
    #'   own history. Set to `Inf` to disable.
    #' @param max_steps Hard budget: the maximum number of code executions
    #'   the agent gets in this session. Unlike the stopping rules (which the
    #'   agent applies itself), this is mechanically enforced - past the
    #'   limit the `run_r_code` tool refuses to execute and instructs the
    #'   agent to finalise from what it has. `Inf` (default) disables.
    #' @param max_runtime Hard budget: wall-clock seconds for this session
    #'   process, enforced the same way as `max_steps`. Timing restarts on
    #'   [atlas_resume()]. `Inf` (default) disables.
    initialize = function(data, outcome, n_models = 3, goal = NULL,
                          constraints = NULL, chat = NULL, dir = NULL,
                          on_ask = NULL, display = c("console", "markdown"),
                          stopping_rounds = 3, stopping_tolerance = 0.05, exclude = NULL,
                          interject = NULL, autonomous = FALSE,
                          test_prop = 0, compact_at = 1e5,
                          max_steps = Inf, max_runtime = Inf) {
      stopifnot(is.numeric(max_steps), max_steps >= 1,
                is.numeric(max_runtime), max_runtime > 0)
      private$compact_at <- compact_at
      private$max_steps <- max_steps
      private$max_runtime <- max_runtime
      private$deadline <- if (is.finite(max_runtime)) {
        Sys.time() + max_runtime
      }
      private$on_ask <- on_ask
      private$interject <- interject
      private$display <- match.arg(display)
      stopifnot(is.data.frame(data), is.character(outcome), length(outcome) == 1,
                is.numeric(n_models), length(n_models) == 1, n_models >= 1,
                is.numeric(stopping_rounds), stopping_rounds >= 1,
                is.numeric(stopping_tolerance), stopping_tolerance >= 0, stopping_tolerance <= 1,
                is.numeric(test_prop), test_prop >= 0, test_prop < 1)
      if (!outcome %in% names(data)) {
        stop("outcome '", outcome, "' is not a column of `data`", call. = FALSE)
      }
      if (outcome %in% exclude) {
        stop("the outcome cannot be excluded", call. = FALSE)
      }
      data <- data[setdiff(names(data), exclude)]
      if (test_prop > 0) {
        idx <- seeded_sample(nrow(data), max(1, round(nrow(data) * test_prop)))
        self$test_data <- data[idx, , drop = FALSE]
        data <- data[-idx, , drop = FALSE]
      }
      leakage <- tryCatch(atlas_leakage_screen(data, outcome),
                          error = function(e) NULL)
      private$meta <- list(outcome = outcome, n_models = n_models, goal = goal,
                           constraints = normalize_constraints(constraints),
                           stopping_rounds = stopping_rounds, stopping_tolerance = stopping_tolerance,
                           exclude = exclude, leakage = leakage,
                           autonomous = autonomous, test_prop = test_prop,
                           compact_at = compact_at,
                           max_steps = max_steps, max_runtime = max_runtime)
      self$dir <- path.expand(
        dir %||% file.path(getOption("atlas.dir", ".atlas"),
                           format(Sys.time(), "%Y%m%d-%H%M%S")))
      dir.create(self$dir, recursive = TRUE, showWarnings = FALSE)
      saveRDS(data, file.path(self$dir, "data.rds"))
      if (!is.null(self$test_data)) {
        saveRDS(self$test_data, file.path(self$dir, "test.rds"))
      }
      tally_path <- file.path(self$dir, "tally.csv")
      if (file.exists(tally_path)) {
        # resuming: restore the tally and the derived best/flat state
        self$tally <- utils::read.csv(tally_path)
        private$restore_tally_state()
      }
      saveRDS(private$meta, file.path(self$dir, "meta.rds"))

      self$env <- new.env(parent = globalenv())
      self$env$data <- data
      self$chat <- chat %||% ellmer::chat_anthropic()
      sys_prompt <- atlas_system_prompt(
        n_models, length(private$meta$constraints) > 0,
        stopping_rounds = stopping_rounds, stopping_tolerance = stopping_tolerance,
        has_modelblueprint = mb_available(), autonomous = autonomous,
        max_steps = max_steps, max_runtime = max_runtime)
      if (identical(private$display, "markdown")) {
        sys_prompt <- paste0(
          sys_prompt, "\n\nYour narration and code output are rendered as",
          " markdown in a web app. Narrate in plain markdown (headings,",
          " bold, lists) and never draw ASCII banners, rules, or box art",
          " with cat() - they render badly.")
      }
      sys_prompt <- paste0(
        sys_prompt, "\n\nThe user can send you messages while you work;",
        " they arrive inside tool results marked [MESSAGE FROM THE USER].",
        " Treat them as your highest-priority instruction: acknowledge the",
        " message and adjust your plan before doing anything else.")
      self$chat$set_system_prompt(sys_prompt)
      private$register_tools()
    },

    #' @description Run the full model-building loop. Streams the agent's
    #'   narration and asks for approval/input in the console when needed.
    #'   After the build, machine-checked constraints are verified against
    #'   every final model; violations are sent back to the agent to fix, up
    #'   to `max_fix_rounds` times.
    #' @param verbose Show the agent's narration, code, and output live.
    #' @param max_fix_rounds How many constraint-repair rounds to allow.
    #' @param refine After the winning algorithm is found (and constraints
    #'   pass), iterate on its feature selection and engineering - one change
    #'   per attempt, same validation scheme - until the session's stopping
    #'   rules trigger (`stopping_rounds` attempts without a `stopping_tolerance` gain).
    #'   The refined model is added to the results alongside the original.
    #' @param validate Produce reviewable validation output (gain,
    #'   calibration, grouped residuals, one-ways, PDPs) for the winning
    #'   model as interactive HTML files in the run directory. Needs the
    #'   `modelblueprint` package; silently skipped when it isn't installed.
    #' @return An `atlas` results object (invisibly); see `$results()`.
    build = function(verbose = TRUE, max_fix_rounds = 2, refine = TRUE,
                     validate = TRUE) {
      self$tell(atlas_task_prompt(self$env$data, private$meta),
                verbose = verbose)
      private$fix_constraints(max_fix_rounds, verbose)
      if (refine && !is.null(self$env$atlas_models) &&
          !private$budget_exhausted()) {
        self$tell(atlas_refine_prompt(private$meta), verbose = verbose)
        private$fix_constraints(max_fix_rounds, verbose)
      }
      if (validate && !is.null(self$env$atlas_models) &&
          !private$budget_exhausted()) {
        if (mb_available()) {
          self$tell(atlas_validation_prompt(self$dir), verbose = verbose)
        } else if (verbose) {
          cli::cli_alert_info(paste(
            "modelblueprint is not installed; skipping the validation",
            "workup for the winning model."))
        }
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
      stopifnot(is.character(text), length(text) == 1)
      private$verbose <- verbose
      if (private$context_tokens() >= private$compact_at) {
        self$compact()
      }
      if (private$compacted) {
        text <- paste0(atlas_compact_briefing(self), "\n\n---\n\n", text)
        private$compacted <- FALSE
      }
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
      test_lb <- NULL
      if (!is.null(self$test_data) && !is.null(self$env$atlas_models)) {
        test_lb <- evaluate_on_test(self$env$atlas_models, self$test_data,
                                    private$meta$outcome)
        utils::write.csv(test_lb, file.path(self$dir, "test_leaderboard.csv"),
                         row.names = FALSE)
      }
      structure(
        list(models = self$env$atlas_models,
             leaderboard = self$env$atlas_leaderboard,
             test_leaderboard = test_lb,
             tally = self$tally,
             constraints = self$check(),
             report = private$last_report, code = self$code,
             cost = tryCatch(self$chat$get_cost(), error = function(e) NULL),
             dir = self$dir, session = self),
        class = "atlas"
      )
    },

    #' @description Compact the conversation to save tokens: archive the
    #'   transcript to the run directory, clear the context window, and
    #'   re-orient the agent with a state briefing on the next message. The
    #'   R environment (models, data) and code log are untouched - they are
    #'   the durable memory. Called automatically when the context exceeds
    #'   `compact_at`; call it yourself before a long follow-up to start
    #'   from a lean window.
    compact = function() {
      turns <- self$chat$get_turns()
      if (length(turns) == 0) return(invisible(self))
      n <- length(list.files(self$dir, pattern = "^turns-archive-")) + 1
      saveRDS(turns, file.path(self$dir, sprintf("turns-archive-%02d.rds", n)))
      self$chat$set_turns(list())
      private$compacted <- TRUE
      if (private$verbose) {
        if (identical(private$display, "markdown")) {
          cat("\n> **Context compacted** to save tokens; the full",
              "transcript is archived in the run directory.\n\n")
        } else {
          cli::cli_alert_info(paste(
            "Context compacted to save tokens; full transcript archived",
            "in the run directory."))
        }
      }
      invisible(self)
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
      cat("<atlas_session>", self$dir, "-",
          length(self$code), "code chunks run,",
          if (is.null(self$env$atlas_models)) "no models yet"
          else paste(length(self$env$atlas_models), "models built"), "\n")
      invisible(self)
    }
  ),

  private = list(
    meta = NULL,
    last_report = NULL,
    compact_at = 1e5,
    compacted = FALSE,
    max_steps = Inf,
    max_runtime = Inf,
    deadline = NULL,
    steps = 0,
    best_value = NULL,
    best_name = NULL,
    flat_count = 0,
    higher_better = NULL,

    # the mechanical keep/discard ledger behind the record_attempt tool:
    # atlas does the comparison and the counting, not the agent
    record_attempt = function(name, metric, value, higher_better) {
      if (is.null(private$higher_better)) {
        private$higher_better <- isTRUE(higher_better)
      }
      hb <- private$higher_better
      tol <- private$meta$stopping_tolerance
      if (!is.finite(value)) {
        verdict <- "DISCARD (metric is not a finite number)"
        private$flat_count <- private$flat_count + 1
      } else if (is.null(private$best_value)) {
        verdict <- "KEEP (baseline)"
        private$best_value <- value
        private$best_name <- name
      } else {
        margin <- tol * abs(private$best_value)
        improved <- if (hb) value >= private$best_value + margin
                    else value <= private$best_value - margin
        if (improved) {
          verdict <- sprintf("KEEP (new best; previous %s = %s)",
                             private$best_name, format(private$best_value))
          private$best_value <- value
          private$best_name <- name
          private$flat_count <- 0
        } else {
          private$flat_count <- private$flat_count + 1
          verdict <- sprintf(
            "DISCARD (no material improvement on best %s = %s; revert this change)",
            private$best_name, format(private$best_value))
        }
      }
      row <- data.frame(attempt = NROW(self$tally) + 1, name = name,
                        metric = metric, value = value,
                        best = private$best_value %||% NA_real_,
                        verdict = sub(" .*", "", verdict))
      self$tally <- rbind(self$tally, row)
      utils::write.csv(self$tally, file.path(self$dir, "tally.csv"),
                       row.names = FALSE)

      stalled <- private$flat_count >= private$meta$stopping_rounds
      if (stalled) {
        verdict <- paste0(
          verdict, " STOPPING RULE TRIGGERED: ", private$flat_count,
          " consecutive attempts without improvement - stop iterating and",
          " finalise.")
      }
      if (private$verbose) {
        line <- sprintf(
          "tally #%d | %s: %s = %s | best: %s = %s | flat: %d/%d -> %s",
          row$attempt, name, metric, format(value),
          private$best_name %||% "-", format(private$best_value %||% NA),
          private$flat_count, as.integer(private$meta$stopping_rounds),
          sub(" .*", "", verdict))
        if (identical(private$display, "markdown")) {
          cat("\n**", line, "**\n\n", sep = "")
        } else {
          cat(cli::col_grey(paste0("[", line, "]")), "\n")
        }
      }
      verdict
    },

    restore_tally_state = function() {
      t <- self$tally
      if (NROW(t) == 0) return(invisible(NULL))
      kept <- t[t$verdict == "KEEP", , drop = FALSE]
      if (nrow(kept) > 0) {
        private$best_value <- kept$value[nrow(kept)]
        private$best_name <- kept$name[nrow(kept)]
      }
      last_keep <- max(c(0, which(t$verdict == "KEEP")))
      private$flat_count <- nrow(t) - last_keep
    },

    # steering channel: a message file in the run dir works for every
    # session (autonomous console runs included); a front-end hook, if
    # supplied, is polled as well
    poll_interject = function() {
      f <- file.path(self$dir, "message.txt")
      if (file.exists(f)) {
        msg <- paste(readLines(f, warn = FALSE), collapse = "\n")
        file.remove(f)
        if (nzchar(trimws(msg))) return(msg)
      }
      if (!is.null(private$interject)) private$interject() else NULL
    },

    budget_reason = function() {
      if (private$steps >= private$max_steps) {
        sprintf("the %d-step limit is used up", as.integer(private$max_steps))
      } else if (!is.null(private$deadline) && Sys.time() >= private$deadline) {
        "the wall-clock time limit has passed"
      }
    },

    budget_exhausted = function() !is.null(private$budget_reason()),

    # warning banner appended to tool results once 80% of a budget is spent
    budget_note = function() {
      parts <- c(
        if (is.finite(private$max_steps) &&
            private$steps >= 0.8 * private$max_steps) {
          sprintf("%d of %d code executions used", private$steps,
                  as.integer(private$max_steps))
        },
        if (!is.null(private$deadline)) {
          left <- as.numeric(difftime(private$deadline, Sys.time(),
                                      units = "secs"))
          if (left <= 0.2 * private$max_runtime) {
            sprintf("%.0f minutes of runtime left", max(0, left) / 60)
          }
        }
      )
      if (length(parts) == 0) return(NULL)
      paste0("[BUDGET WARNING: ", paste(parts, collapse = "; "),
             ". Prioritise finalising `atlas_models`, `atlas_leaderboard`, ",
             "and your report before execution is blocked.]")
    },

    # tokens of the most recent request = current context size; cached
    # input still occupies the window, so count it too
    context_tokens = function() {
      t <- tryCatch(self$chat$get_tokens(), error = function(e) NULL)
      if (is.null(t) || nrow(t) == 0) return(0)
      last <- t[nrow(t), , drop = FALSE]
      cached <- if ("cached_input" %in% names(t)) last$cached_input else 0
      sum(last$input, cached, na.rm = TRUE)
    },

    fix_constraints = function(max_fix_rounds, verbose) {
      for (round in seq_len(max_fix_rounds)) {
        if (private$budget_exhausted()) break
        fails <- self$check()
        fails <- fails[!is.na(fails$passed) & !fails$passed, , drop = FALSE]
        if (nrow(fails) == 0) break
        self$tell(atlas_fix_prompt(fails), verbose = verbose)
      }
    },
    verbose = TRUE,
    on_ask = NULL,
    interject = NULL,
    display = "console",

    register_tools = function() {
      self$chat$register_tool(ellmer::tool(
        function(code) {
          reason <- private$budget_reason()
          if (!is.null(reason)) {
            return(paste0(
              "BUDGET EXHAUSTED (", reason, "): code execution is now ",
              "blocked - this is enforced mechanically, do not retry. ",
              "Objects already in the session (atlas_models, ",
              "atlas_leaderboard) remain in place. Write your final report ",
              "now from what you already know."))
          }
          private$steps <- private$steps + 1
          code <- trimws(code)
          self$code[[length(self$code) + 1]] <- code
          md <- identical(private$display, "markdown")
          if (private$verbose) {
            if (md) {
              cat("\n```r\n", code, "\n```\n", sep = "")
            } else {
              cat("\n")
              cli::cli_rule(left = "R")
              cat(code, "\n", sep = "")
            }
          }
          segs <- atlas_run_segments(code, self$env)
          out <- truncate_output(segments_to_text(segs))
          self$checkpoint()
          budget <- private$budget_note()
          if (!is.null(budget)) out <- paste0(out, "\n\n", budget)
          note <- private$poll_interject()
          if (is.character(note) && length(note) == 1 && nzchar(note)) {
            out <- paste0(
              out, "\n\n[MESSAGE FROM THE USER - highest priority]: ", note,
              "\nAcknowledge this message and adjust your work before",
              " continuing.")
            if (private$verbose) {
              if (identical(private$display, "markdown")) {
                cat("\n> **You interjected:** ",
                    gsub("\n", "\n> ", note), "\n\n", sep = "")
              } else {
                cli::cli_rule(left = "user interjection")
                cat(note, "\n")
              }
            }
          }
          if (private$verbose) {
            if (md) {
              for (s in segs) {
                if (s$type == "table") {
                  cat("\n", md_table(s$df), "\n", sep = "")
                } else {
                  txt <- paste(s$lines, collapse = "\n#> ")
                  cat("\n```\n#> ", txt, "\n```\n", sep = "")
                }
              }
              cat("\n")
            } else {
              # console: tables as classic aligned R output, never pipes
              for (s in segs) {
                txt <- if (s$type == "table") {
                  paste(utils::capture.output(print_clean(s$df)),
                        collapse = "\n")
                } else {
                  paste(s$lines, collapse = "\n")
                }
                cat(cli::col_grey(paste0("#> ", gsub("\n", "\n#> ", txt))),
                    "\n", sep = "")
              }
              cli::cli_rule()
              cat("\n")
            }
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
          if (!is.null(private$on_ask)) {
            as.character(private$on_ask(question))
          } else if (interactive()) {
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
      self$chat$register_tool(ellmer::tool(
        function(name, metric, value, higher_better) {
          private$record_attempt(name, metric, value, higher_better)
        },
        name = "record_attempt",
        description = paste(
          "Record the validation result of EVERY model or tweak immediately",
          "after evaluating it. Atlas keeps the tally, compares against the",
          "best so far (using the stopping tolerance), and returns a",
          "verdict: KEEP means adopt it; DISCARD means revert the change",
          "completely. Obey the verdict. When the reply says the stopping",
          "rule triggered, stop iterating and finalise."
        ),
        arguments = list(
          name = ellmer::type_string("short label for this model or tweak"),
          metric = ellmer::type_string("validation metric name, e.g. rmse"),
          value = ellmer::type_number("the metric value achieved"),
          higher_better = ellmer::type_boolean(
            "TRUE if larger is better (AUC, accuracy); FALSE for losses (RMSE)")
        )
      ))
      self$chat$register_tool(ellmer::tool(
        function(variable, direction) {
          if (!variable %in% names(self$env$data)) {
            return(paste0("`", variable, "` is not a column of the data."))
          }
          private$meta$constraints[[paste0("mono_", variable)]] <-
            con_monotone(variable, direction)
          saveRDS(private$meta, file.path(self$dir, "meta.rds"))
          paste0("Added machine-checked constraint: predictions must be ",
                 "monotonically ", direction, " in `", variable, "`.")
        },
        name = "add_monotone_constraint",
        description = paste(
          "Add a monotonicity constraint on a predictor. It becomes a hard,",
          "machine-checked constraint verified against every final model.",
          "Only call this after the user has approved the suggestion",
          "(via ask_user)."
        ),
        arguments = list(
          variable = ellmer::type_string("exact column name in `data`"),
          direction = ellmer::type_enum(
            c("increasing", "decreasing"),
            "direction of the effect on predictions")
        )
      ))
      self$chat$register_tool(ellmer::tool(
        function() {
          df <- self$check()
          if (nrow(df) == 0) {
            return(paste("Nothing to check yet - either no machine-checked",
                         "constraints are set or `atlas_models` is empty."))
          }
          tbl <- md_table(df)
          if (private$verbose) {
            if (identical(private$display, "markdown")) {
              cat("\n**Rules check**\n\n", tbl, "\n\n", sep = "")
            } else {
              cat("\n")
              cli::cli_rule(left = "constraint check")
              print_clean(df)
              cli::cli_rule()
              cat("\n")
            }
          }
          tbl
        },
        name = "check_constraints",
        description = paste(
          "Verify every machine-checked constraint against the models in",
          "`atlas_models`. Run this after creating `atlas_models` and fix",
          "any failures before finishing."
        )
      ))
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
#' Rebuilds an [atlas_session] after a crash or R restart: reloads the data,
#' replays every recorded code chunk to reconstruct the working environment
#' (models included), and restores the conversation so the agent remembers
#' everything it did.
#'
#' @param dir A run directory created by a previous session.
#' @param chat Optionally a fresh ellmer chat object (must be tool-capable);
#'   defaults to `ellmer::chat_anthropic()`.
#' @param ... Passed on to the [atlas_session] constructor, e.g. `on_ask` or
#'   `display` when resuming inside a front-end.
#' @return An [atlas_session].
#' @examples
#' \dontrun{
#' s <- atlas_resume(".atlas/20260703-141500")
#' s$tell("continue where you left off")
#' }
#' @export
atlas_resume <- function(dir, chat = NULL, ...) {
  meta <- readRDS(file.path(dir, "meta.rds"))
  data <- readRDS(file.path(dir, "data.rds"))
  s <- atlas_session$new(data, meta$outcome, n_models = meta$n_models,
                        goal = meta$goal, constraints = meta$constraints,
                        chat = chat, dir = dir,
                        stopping_rounds = meta$stopping_rounds %||%
                          meta$patience %||% 3,
                        stopping_tolerance = meta$stopping_tolerance %||%
                          meta$min_improve %||% 0.05,
                        autonomous = meta$autonomous %||% FALSE,
                        compact_at = meta$compact_at %||% 1e5,
                        max_steps = meta$max_steps %||% Inf,
                        max_runtime = meta$max_runtime %||% Inf, ...)
  code_path <- file.path(dir, "code.rds")
  if (file.exists(code_path)) {
    s$code <- readRDS(code_path)
    # ponytail: environments aren't reliably serializable; replaying the code
    # log with the original data is exact reconstruction (agent code is seeded)
    for (chunk in s$code) atlas_run_code(chunk, s$env)
  }
  turns_path <- file.path(dir, "turns.rds")
  if (file.exists(turns_path)) s$chat$set_turns(readRDS(turns_path))
  test_path <- file.path(dir, "test.rds")
  if (file.exists(test_path)) s$test_data <- readRDS(test_path)
  s
}

#' Send a message to a running atlas session
#'
#' Steer a build that is already underway - even a fully autonomous one -
#' from any other R session or terminal. The message is written to the run
#' directory and delivered to the agent with its next tool result, marked as
#' its highest-priority instruction: "focus on gradient boosting", "stop
#' engineering interactions and tune the winner", "drop CREDIT_GRADE, it is
#' not available in deployment".
#'
#' Delivery happens at the agent's next code execution, so a message lands
#' within one step; one sent after the run finishes is simply never picked
#' up (use [atlas_resume()] and `$tell()` instead).
#'
#' @param dir The run directory of the session to steer.
#' @param text What to tell the agent.
#' @return `dir`, invisibly.
#' @examples
#' \dontrun{
#' # terminal 1: an unattended experiment loop
#' atlas(claims, "severity", autonomous = TRUE, test_prop = 0.2,
#'       dir = "~/runs/severity")
#'
#' # terminal 2, twenty minutes later:
#' atlas_message("~/runs/severity",
#'               "focus on the gamma GLM family; stop trying trees")
#' }
#' @export
atlas_message <- function(dir, text) {
  stopifnot(is.character(text), length(text) == 1, nzchar(trimws(text)))
  if (!dir.exists(dir)) {
    stop("no run directory at '", dir, "'", call. = FALSE)
  }
  writeLines(text, file.path(dir, "message.txt"))
  invisible(dir)
}

# Post-compaction re-orientation, built from session state rather than an
# LLM summary: costs nothing and can't invent anything.
atlas_compact_briefing <- function(s) {
  models <- s$env$atlas_models
  lb <- s$env$atlas_leaderboard
  paste0(
    "NOTE: this conversation was compacted to save tokens. Nothing else was",
    " lost - your R session is fully intact:\n",
    "- models in `atlas_models`: ",
    if (length(models)) paste(names(models), collapse = ", ") else "none yet",
    "\n- current leaderboard:\n",
    if (is.data.frame(lb) && nrow(lb) > 0) md_table(lb) else "(none yet)",
    "\n- ", length(s$code), " code chunks executed so far (full log in",
    " code.R in the run directory)\n",
    "Re-orient by printing objects if you are unsure of any detail, then",
    " continue with the task below."
  )
}

# Deterministic sample that leaves the caller's RNG stream untouched -
# including removing .Random.seed again if it didn't exist before.
seeded_sample <- function(n, size, seed = 1) {
  had <- exists(".Random.seed", globalenv(), inherits = FALSE)
  old <- if (had) get(".Random.seed", globalenv())
  on.exit(
    if (had) assign(".Random.seed", old, globalenv())
    else suppressWarnings(rm(".Random.seed", envir = globalenv())),
    add = TRUE)
  set.seed(seed)
  sample.int(n, size)
}

# Pick a sensible test metric from the outcome: RMSE for continuous
# outcomes, accuracy otherwise (thresholding numeric predictions at 0.5
# for binary targets).
auto_metric <- function(y) {
  if (is.numeric(y) && length(unique(y)) > 5) {
    list(name = "rmse", higher_better = FALSE,
         fn = function(actual, predicted) {
           sqrt(mean((actual - as.numeric(predicted))^2))
         })
  } else {
    list(name = "accuracy", higher_better = TRUE,
         fn = function(actual, predicted) {
           if (is.numeric(predicted) && is.numeric(actual) &&
               all(actual %in% c(0, 1))) {
             predicted <- as.numeric(predicted >= 0.5)
           }
           mean(as.character(actual) == as.character(predicted))
         })
  }
}

# Atlas-side final evaluation: the agent never touches the test rows, so
# this ranking can't be gamed. Models that can't predict get NA, not an
# error - one broken candidate shouldn't sink the run.
evaluate_on_test <- function(models, test, outcome) {
  m <- auto_metric(test[[outcome]])
  rows <- lapply(names(models), function(nm) {
    value <- tryCatch(
      m$fn(test[[outcome]], stats::predict(models[[nm]], newdata = test)),
      error = function(e) NA_real_)
    data.frame(model = nm, metric = m$name, value = value)
  })
  out <- do.call(rbind, rows)
  out[order(out$value, decreasing = m$higher_better, na.last = TRUE), ,
      drop = FALSE]
}

# modelblueprint is optional: only mention it to the agent (and only allow
# its file writes) when it is actually installed
mb_available <- function() {
  requireNamespace("modelblueprint", quietly = TRUE)
}

atlas_system_prompt <- function(n_models, has_constraints = FALSE,
                                stopping_rounds = 3, stopping_tolerance = 0.05,
                                has_modelblueprint = TRUE,
                                autonomous = FALSE,
                                max_steps = Inf, max_runtime = Inf) {
  paste(
    "You are Atlas, an expert R statistician and ML engineer. You build models",
    "by writing R code and running it with the run_r_code tool. You can ask",
    "the user questions with the ask_user tool.",
    "",
    sprintf("Your job: build up to %d distinct candidate models for the stated outcome,", n_models),
    "stopping earlier if the stopping rules trigger.",
    "",
    "Stopping rules (they apply to adding candidate models AND to any",
    "iterative loop, such as refining features or tuning a model):",
    "- After evaluating EVERY candidate or tweak, call record_attempt with",
    "  its validation result. Atlas keeps the live tally and does the",
    "  comparison for you.",
    "- Obey the verdict: KEEP means adopt the model/change; DISCARD means",
    "  revert it completely and do not keep it in `atlas_models`.",
    "- An attempt counts as an improvement only if it beats the best",
    sprintf("  validation metric so far by at least %s%% (relative).",
            format(stopping_tolerance * 100)),
    sprintf("- record_attempt tells you when %d consecutive attempts have not",
            as.integer(stopping_rounds)),
    "  improved: stop iterating at that point.",
    "- Always say in your report why you stopped (limit reached, converged, ...).",
    if (is.finite(max_steps) || is.finite(max_runtime)) paste0(
      "- Hard budget, enforced mechanically (execution is BLOCKED once it",
      "\n  runs out - budget warnings appear in tool results): ",
      paste(c(
        if (is.finite(max_steps)) sprintf("%d code executions",
                                          as.integer(max_steps)),
        if (is.finite(max_runtime)) sprintf("%.0f minutes of runtime",
                                            max_runtime / 60)),
        collapse = " and "),
      ".\n  Always leave room to finalise `atlas_models`,",
      " `atlas_leaderboard`, and the report."),
    "",
    "Workflow:",
    "1. Explore the data: dimensions, types, missingness, and the outcome's",
    "   distribution (type, skew, zeros, bounds, outliers). Narrate briefly.",
    "   Watch for target leakage: predictors flagged in the task, variables",
    "   with a suspiciously perfect association with the outcome, and",
    "   variables that could not be known at prediction time. Confirm",
    "   suspicious ones with ask_user and drop confirmed leaks entirely.",
    "2. Propose a plan DRIVEN BY the outcome's distribution: choose model",
    "   families, link functions and any target transformation to match it",
    "   (binary -> binomial; counts -> Poisson-family; skewed positive ->",
    "   Gamma/Tweedie or log transform; symmetric continuous -> Gaussian),",
    "   and state that reasoning. Include the validation scheme (holdout or",
    "   CV, fixed seed). Also consider which predictors should have a",
    "   monotone effect on the outcome as a matter of domain sense (e.g. a",
    "   house's price should not fall as floor area grows); include any such",
    if (autonomous) paste0(
      "   suggestions, with direction and a one-line why, in the plan. You",
      "\n   are running autonomously: state the plan, apply monotone",
      "\n   constraints that are clearly right on domain grounds via",
      "\n   add_monotone_constraint, and proceed without waiting.")
    else paste0(
      "   suggestions, with direction and a one-line why, in the plan. Present",
      "\n   the plan with ask_user, explicitly inviting approval, changes, or",
      "\n   extra instructions. Incorporate whatever the user says - if they ask",
      "\n   for substantial changes, restate the revised plan in one short",
      "\n   paragraph before proceeding - and call add_monotone_constraint for",
      "\n   each monotone suggestion the user approves. Never start fitting",
      "\n   until the user has responded."),
    if (autonomous) paste0(
      "3. Never call ask_user in this run - no one will answer. Make",
      "\n   reasonable decisions yourself and record them in your narration.",
      "\n   The user may still inject messages mid-run (they arrive in tool",
      "\n   results marked [MESSAGE FROM THE USER]); obey them immediately.")
    else paste0(
      "3. The user may also steer you mid-build (through ask_user answers or",
      "\n   messages in tool results): treat instructions like 'focus on",
      "\n   improvements' or 'change the feature engineering' as immediate",
      "\n   course corrections, acknowledge them, and adjust the plan."),
    "4. Fit and evaluate each candidate on held-out data. After each one,",
    "   narrate one line: model name, metric, value.",
    "5. Refit each candidate on all rows for the final versions.",
    "6. Create in the R session:",
    "   - `atlas_models`: named list of the final fitted models",
    "   - `atlas_leaderboard`: data.frame(name, type, metric, value, notes),",
    "     sorted best first, from the held-out evaluation",
    "7. End with a markdown report: data summary; one section per model",
    "   covering how it was built (preprocessing, features, tuning) and its",
    "   validation performance; a recommendation of which model to use.",
    "",
    "Rules:",
    if (has_modelblueprint) paste0(
      "- Never call install.packages() or access the network. Never read or",
      "\n  write files, with one exception: modelblueprint's output helpers",
      "\n  (model_validation(), save_plots()) may write into the run",
      "\n  directory when a task asks for it.")
    else paste0(
      "- Never call install.packages(), read or write files, or access the",
      "\n  network."),
    "- Prefer base R; check optional packages with requireNamespace() and fall",
    "  back gracefully if missing.",
    "- Keep each code chunk small; inspect output before continuing.",
    if (autonomous)
      "- Never call ask_user: no user is available for this run."
    else
      "- Use ask_user when a decision genuinely needs the user; otherwise proceed.",
    "- Constraints can be added mid-session with add_monotone_constraint.",
    "  Machine checks require `predict(model, newdata)` to work on a",
    "  data.frame like `data`; make sure every model in `atlas_models`",
    "  supports that. After creating `atlas_models`, run the check_constraints",
    "  tool and fix any failures before finishing.",
    if (has_constraints) paste(
      "- The task lists hard constraints. Every final model must satisfy all",
      "\n  of them. Design for them from the start (e.g. sign-constrained or",
      "\n  monotone model forms), don't bolt them on afterwards."),
    sep = "\n"
  )
}

atlas_refine_prompt <- function(meta) {
  paste0(
    "The candidates are built. Now refine the winner - the best model on ",
    "`atlas_leaderboard` - to find the optimum version of it:\n",
    "1. Iterate on feature selection and feature engineering, ONE change per ",
    "attempt: add or drop predictors, transformations, interactions, ",
    "binning, encodings. Refit and evaluate every attempt with the same ",
    "validation scheme and metric as before, and narrate one line per ",
    "attempt: what changed, the metric, the best so far.\n",
    sprintf(paste0(
      "2. Apply the stopping rules: stop after %d consecutive attempts ",
      "without improvement; a gain under %s%% (relative) does not count as ",
      "improvement.\n"),
      as.integer(meta$stopping_rounds), format(meta$stopping_tolerance * 100)),
    "3. Hard constraints still apply to every attempt",
    if (length(meta$constraints) > 0) " (verify with check_constraints)",
    ".\n",
    "4. When you stop: refit the best refined version on all rows, add it ",
    "to `atlas_models` under the winner's name with '_refined' appended ",
    "(keep the original too), add a matching `atlas_leaderboard` row, and ",
    "summarise: attempts made, what improved, and why you stopped."
  )
}

atlas_validation_prompt <- function(dir) {
  paste0(
    "The winning model now needs reviewable validation output, produced with ",
    "the modelblueprint package (it is installed). File writing is allowed ",
    "for this step, but only through modelblueprint's own helpers ",
    "(model_validation(), save_plots(), plus dir.create() for their output ",
    "folders), all inside '", dir, "'.\n\n",
    "1. Wrap the winning model USING THE EXACT SPLIT FROM YOUR VALIDATION ",
    "SCHEME - the plots are only meaningful if train and test really are ",
    "the rows the model was and wasn't fitted on. Never pass the full ",
    "dataset as train or test:\n",
    "   mb <- modelblueprint::modelblueprint(\n",
    "     model = <winning model, refit on the TRAINING rows only>,\n",
    "     train = <the training rows>, test = <your held-out rows>,\n",
    "     y_name = <outcome column>,\n",
    "     x_original_inputs = <character vector of predictor columns>,\n",
    "     model_display_name = <winner's leaderboard name>,\n",
    "     deploy_notes = <one-line description of how it was built>)\n",
    "2. Validation plots (gain, calibration, grouped residuals) for BOTH ",
    "splits:\n",
    "   modelblueprint::model_validation(mb, sets = c('train', 'test'),\n",
    "     plots = 'validation', filepath = '", dir, "')\n",
    "   (this also saves the blueprint as a portable ",
    "<model_display_name>.tar.gz bundle)\n",
    "3. One-way plots: ONE file covering all variables, on the train set:\n",
    "   ow <- modelblueprint::one_way(mb, var = NA, set = 'train',\n",
    "                                 predictions = TRUE)\n",
    "   dir.create(file.path('", dir, "', mb@model_display_name, 'oneway'),\n",
    "              recursive = TRUE, showWarnings = FALSE)\n",
    "   modelblueprint::save_plots(ow, file.path('", dir, "',\n",
    "     mb@model_display_name, 'oneway', 'oneway_all_vars.html'))\n",
    "   (if var = NA errors in your installed version, build the list",
    " yourself - lapply one_way() over every predictor - and save it with",
    " that same single save_plots() call)\n",
    "4. PDPs for the TRAIN set only:\n",
    "   modelblueprint::model_validation(mb, sets = 'train', plots = 'pdp',\n",
    "     filepath = '", dir, "')\n",
    "5. Do NOT create any other artifacts: no saveRDS(), no README files, no",
    " helper scripts. The package's own workflow covers reloading and",
    " interactive review.\n",
    "6. Finish with a short review guide that uses these exact commands and",
    " paths (they are relative to the R session's working directory, so they",
    " work as written):\n",
    "   - open the HTML files under '", dir, "/<model_display_name>/'\n",
    "   - reload the blueprint:\n",
    "     mb <- modelblueprint::loadmb('", dir,
    "/<model_display_name>/<model_display_name>.tar.gz')\n",
    "   - interactive dashboard: modelblueprint::mb_dashboard(mb)\n",
    "   plus one paragraph on what to look at first and anything that needs",
    " a reviewer's attention."
  )
}

atlas_task_prompt <- function(data, meta) {
  profile <- utils::capture.output(utils::str(data, list.len = 50))
  # unlist() drops the NULLs from inactive sections, so no blank gaps
  parts <- list(
    sprintf("Build up to %d models predicting `%s` from the other columns.",
            meta$n_models, meta$outcome),
    sprintf("The data.frame `data` has %d rows and %d columns:",
            nrow(data), ncol(data)),
    paste(profile, collapse = "\n"),
    if (isTRUE(meta$test_prop > 0)) paste0(
      "A further ", round(meta$test_prop * 100), "% of rows has been held ",
      "out as a final test set that you will NEVER see. Every final model ",
      "is evaluated on it after the run, so optimise for genuine ",
      "generalisation, not for your own validation score."),
    if (length(meta$exclude) > 0) paste0(
      "The user excluded these columns (unavailable at prediction time, or ",
      "leakage risk); they have already been removed from `data`: ",
      paste(meta$exclude, collapse = ", "), "."),
    if (!is.null(meta$leakage) && any(meta$leakage$flagged)) paste0(
      "Automated leakage screen - these predictors alone explain almost all ",
      "of the outcome, which usually means leakage:\n",
      paste(sprintf("- %s (univariate R-squared %.3f)",
                    meta$leakage$variable[meta$leakage$flagged],
                    meta$leakage$r2[meta$leakage$flagged]),
            collapse = "\n"),
      "\nConfirm with the user (ask_user) whether each is legitimately ",
      "available at prediction time before relying on it; drop confirmed ",
      "leaks entirely."),
    if (length(meta$constraints) > 0) paste0(
      "Hard constraints - every final model must satisfy ALL of these:\n",
      paste(sprintf("%d. [%s] %s%s",
                    seq_along(meta$constraints), names(meta$constraints),
                    vapply(meta$constraints, `[[`, "", "description"),
                    ifelse(vapply(meta$constraints,
                                  function(ci) is.null(ci$check), logical(1)),
                           "", " (machine-checked)")),
            collapse = "\n")),
    if (!is.null(meta$goal)) paste("Additional instructions:", meta$goal)
  )
  paste(unlist(parts), collapse = "\n\n")
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
  truncate_output(segments_to_text(atlas_run_segments(code, env)), max_chars)
}

truncate_output <- function(out, max_chars = 8000) {
  if (out == "") out <- "(no output)"
  if (nchar(out) > max_chars) {
    out <- paste0(substr(out, 1, max_chars), "\n... [truncated]")
  }
  out
}

# Evaluate a chunk, returning segments: list(type = "text", lines) for plain
# printed output, list(type = "table", df) for tabular visible values - so
# front-ends can render tables properly instead of as monospace dumps.
atlas_run_segments <- function(code, env, max_rows = 30) {
  segs <- list()
  add_text <- function(lines) {
    if (length(lines) && any(nzchar(lines))) {
      segs[[length(segs) + 1]] <<- list(type = "text", lines = lines)
    }
  }
  handled <- tryCatch({
    for (expr in parse(text = code)) {
      side <- utils::capture.output(res <- withVisible(eval(expr, env)))
      add_text(side)
      if (res$visible) {
        tab <- as_table_df(res$value, max_rows)
        if (is.null(tab)) {
          add_text(utils::capture.output(print(res$value)))
        } else {
          segs[[length(segs) + 1]] <- list(type = "table", df = tab$df)
          if (!is.null(tab$note)) add_text(tab$note)
        }
      }
    }
    TRUE
  },
  error = function(e) paste("Error:", conditionMessage(e)),
  warning = function(w) paste("Warning:", conditionMessage(w)))
  if (!isTRUE(handled)) segs <- list(list(type = "text", lines = handled))
  coalesce_text(segs)
}

# Merge adjacent text segments so a chunk with many cat()/print() calls
# renders as one block, not a stack of one-line fragments.
coalesce_text <- function(segs) {
  out <- list()
  for (s in segs) {
    n <- length(out)
    if (identical(s$type, "text") && n > 0 && identical(out[[n]]$type, "text")) {
      out[[n]]$lines <- c(out[[n]]$lines, s$lines)
    } else {
      out[[n + 1]] <- s
    }
  }
  out
}

# Visible value -> data.frame for tabular rendering, or NULL to fall back to
# print(). Covers data.frames, 1-D/2-D tables (incl. summary()), numeric
# matrices, and named atomic vectors like colSums() results.
as_table_df <- function(v, max_rows = 30) {
  df <- if (is.data.frame(v)) {
    if (is.character(attr(v, "row.names"))) {
      cbind(row = rownames(v), v, row.names = NULL)
    } else {
      v
    }
  } else if (inherits(v, "table") && length(dim(v)) == 2 && is.numeric(v)) {
    # numeric only: summary(data.frame) is a character "table" of padded
    # strings that reads far better as plain print output
    m <- as.data.frame.matrix(v)
    cbind(" " = rownames(m), m, row.names = NULL)
  } else if ((inherits(v, "table") || inherits(v, "summaryDefault") ||
              is.atomic(v)) &&
             length(dim(v)) <= 1 && !is.null(names(v)) &&
             length(v) > 1 && length(v) <= 500) {
    data.frame(name = names(v), value = unname(as.vector(v)))
  } else if (is.matrix(v) && is.numeric(v)) {
    m <- as.data.frame(v)
    if (!is.null(rownames(v))) cbind(row = rownames(v), m, row.names = NULL)
    else m
  }
  if (is.null(df) || ncol(df) == 0) return(NULL)
  note <- NULL
  if (nrow(df) > max_rows) {
    note <- sprintf("... and %d more rows", nrow(df) - max_rows)
    df <- utils::head(df, max_rows)
  }
  list(df = df, note = note)
}

# Flatten segments into the plain string the agent (and the console) sees;
# tables become markdown pipe tables, which models read fine.
segments_to_text <- function(segs) {
  if (!length(segs)) return("")
  paste(vapply(segs, function(s) {
    if (s$type == "table") md_table(s$df)
    else paste(s$lines, collapse = "\n")
  }, character(1)), collapse = "\n")
}
