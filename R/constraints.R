#' Define a hard constraint on the models Atlas builds
#'
#' Constraints carry domain knowledge into the build: the description is put
#' in front of the agent as a hard requirement, and if `check` is supplied the
#' constraint is *verified* — every final model is tested after the build, and
#' violations are sent back to the agent to fix (see `max_fix_rounds` in
#' [atlas()]). Plain strings passed to `constraints` are shorthand for
#' `constraint(<string>)`: enforced via instructions only.
#'
#' @param description What must hold, in plain language. The agent reads this.
#' @param check Optional verification: `function(model, data)` returning
#'   `TRUE` if the constraint holds, or a string describing the violation
#'   (`FALSE` also counts as a violation). Errors count as violations too, so
#'   a check may simply `stop()` on bad models.
#' @return An `atlas_constraint`.
#' @seealso [con_uses()], [con_monotone()] for ready-made checks.
#' @importFrom stats predict
#' @examples
#' constraint("never use the `id` column; it is a row identifier")
#'
#' constraint(
#'   "predictions must never be negative",
#'   check = function(model, data) {
#'     p <- predict(model, newdata = data)
#'     if (all(p >= 0)) TRUE else "some predictions are negative"
#'   }
#' )
#' @export
constraint <- function(description, check = NULL) {
  stopifnot(is.character(description), length(description) == 1,
            is.null(check) || is.function(check))
  structure(list(description = description, check = check),
            class = "atlas_constraint")
}

#' Constraint: the model must use a given variable
#'
#' Machine-checked and model-agnostic: the check shuffles (reverses) the
#' column and compares predictions; if they don't move, the model isn't using
#' the variable. Works for any model that supports
#' `predict(model, newdata = <data.frame>)`.
#'
#' @param var Column name that must contribute to predictions.
#' @return An `atlas_constraint`.
#' @examples
#' # the check itself needs no LLM: it works on any fitted model
#' uses_wt <- con_uses("wt")
#' uses_wt$check(lm(mpg ~ wt + hp, mtcars), mtcars)  # TRUE
#' uses_wt$check(lm(mpg ~ hp, mtcars), mtcars)       # a violation message
#'
#' \dontrun{
#' atlas(mtcars, "mpg", constraints = list(uses_wt = con_uses("wt")))
#' }
#' @export
con_uses <- function(var) {
  force(var)
  constraint(
    sprintf("The variable `%s` must be used as a predictor.", var),
    check = function(model, data) {
      if (!var %in% names(data)) return(sprintf("`%s` is not in the data", var))
      shuffled <- data
      shuffled[[var]] <- rev(shuffled[[var]])
      same <- isTRUE(all.equal(predict(model, newdata = data),
                               predict(model, newdata = shuffled)))
      if (same) {
        sprintf("predictions are unchanged when `%s` is scrambled - the model does not use it", var)
      } else TRUE
    }
  )
}

#' Constraint: predictions must be monotonic in a variable
#'
#' Machine-checked, model-agnostic (ICE-style): for a sample of observed rows,
#' the variable is swept over its observed range with everything else held
#' fixed, and predictions must move in the stated direction every time.
#'
#' Monotonicity is non-strict, so a model that does not use `var` at all
#' passes trivially (a flat response is monotone). This makes the constraint
#' conditional — "if the model responds to `var`, the effect must be
#' monotone" — without forcing the variable in. Pair with [con_uses()] when
#' the variable must also be used.
#'
#' @param var Column name (numeric) the response must be monotonic in.
#' @param direction `"increasing"` or `"decreasing"`.
#' @param tol Tolerance for tiny numeric wiggles.
#' @param n_grid,n_rows Size of the sweep grid and number of rows tested.
#' @return An `atlas_constraint`.
#' @examples
#' mono <- con_monotone("wt", "decreasing")
#' mono$check(lm(mpg ~ wt, mtcars), mtcars)          # TRUE: linear, negative
#' con_monotone("wt", "increasing")$check(lm(mpg ~ wt, mtcars), mtcars)
#'
#' \dontrun{
#' atlas(df, "price", constraints = list(
#'   mono_sqft = con_monotone("sqft", "increasing")
#' ))
#' }
#' @export
con_monotone <- function(var, direction = c("increasing", "decreasing"),
                         tol = 1e-8, n_grid = 25, n_rows = 20) {
  direction <- match.arg(direction)
  force(var); force(tol); force(n_grid); force(n_rows)
  constraint(
    sprintf("Predictions must be monotonically %s in `%s`.", direction, var),
    check = function(model, data) {
      if (!var %in% names(data)) return(sprintf("`%s` is not in the data", var))
      idx <- unique(round(seq(1, nrow(data), length.out = min(n_rows, nrow(data)))))
      grid <- seq(min(data[[var]], na.rm = TRUE), max(data[[var]], na.rm = TRUE),
                  length.out = n_grid)
      for (i in idx) {
        newd <- data[rep(i, n_grid), , drop = FALSE]
        newd[[var]] <- grid
        d <- diff(as.numeric(predict(model, newdata = newd)))
        bad <- if (direction == "increasing") any(d < -tol) else any(d > tol)
        if (bad) {
          return(sprintf("predictions are not monotonically %s in `%s` (violated with other predictors held at row %d's values)",
                         direction, var, i))
        }
      }
      TRUE
    }
  )
}

#' Screen predictors for possible target leakage
#'
#' A quick, model-free screen: for each predictor, how much of the outcome
#' does it explain on its own (R-squared of `lm(outcome ~ predictor)`, with
#' factor outcomes coded to integers)? Near-perfect univariate fits usually
#' mean the column is derived from the outcome or recorded after it - classic
#' leakage. Used automatically by [atlas()] to warn the agent, and by
#' [atlas_app()] to flag columns in the feature picker; also useful on its
#' own before any modeling.
#'
#' @param data A data.frame.
#' @param outcome Name of the outcome column.
#' @param threshold Flag predictors with univariate R-squared at or above
#'   this value.
#' @param max_rows Screen at most this many rows (evenly spaced) for speed.
#' @return A data.frame with `variable`, `r2`, and `flagged`. High-cardinality
#'   factors (e.g. IDs) get `r2 = NA`: they can't be assessed this way, but
#'   are usually unusable as predictors anyway.
#' @examples
#' leaky <- mtcars
#' leaky$mpg_copy <- leaky$mpg * 2
#' atlas_leakage_screen(leaky, "mpg")
#' @export
atlas_leakage_screen <- function(data, outcome, threshold = 0.95,
                                 max_rows = 5000) {
  stopifnot(is.data.frame(data), outcome %in% names(data),
            is.numeric(threshold), length(threshold) == 1,
            threshold > 0, threshold <= 1)
  if (nrow(data) > max_rows) {
    data <- data[unique(round(seq(1, nrow(data), length.out = max_rows))), ,
                 drop = FALSE]
  }
  y <- data[[outcome]]
  if (!is.numeric(y)) y <- as.numeric(as.factor(y))
  vars <- setdiff(names(data), outcome)
  r2 <- vapply(vars, function(v) {
    x <- data[[v]]
    if (all(is.na(x))) return(NA_real_)
    if (!is.numeric(x)) {
      x <- as.factor(x)
      if (nlevels(x) > min(50, nrow(data) / 2)) return(NA_real_)
    }
    # a perfect fit warns "summary may be unreliable" - that IS our signal
    tryCatch(suppressWarnings(summary(stats::lm(y ~ x))$r.squared),
             error = function(e) NA_real_)
  }, numeric(1))
  data.frame(variable = vars, r2 = round(r2, 4),
             flagged = !is.na(r2) & r2 >= threshold, row.names = NULL)
}

#' Extract constraints from a natural-language brief
#'
#' Uses the LLM to parse free text into Atlas constraints, mapping to
#' machine-checked types wherever possible: "wt must be used" becomes
#' [con_uses()], "mpg should never increase with weight" becomes
#' [con_monotone()], and anything else becomes a prompt-enforced
#' [constraint()]. Returns the list for you to inspect (print it!) before
#' passing to [atlas()] — the parse is a judgment call, so review it.
#'
#' @param text The brief, in plain language. Sentences, bullets, whatever.
#' @param data Optional data.frame the constraints are about; its column
#'   names are given to the parser, and extracted variable names are
#'   validated against them (a constraint naming an unknown column falls
#'   back to prompt-only enforcement).
#' @param chat An ellmer chat object; defaults to `ellmer::chat_anthropic()`.
#' @return A named list of [constraint()] objects, ready for the
#'   `constraints` argument of [atlas()] or [AtlasSession].
#' @examples
#' \dontrun{
#' cons <- extract_constraints(
#'   "weight must be in the model; predictions can never go up as
#'    horsepower rises; qsec is post-hoc, never use it",
#'   data = mtcars
#' )
#' cons  # inspect: which became machine checks?
#' res <- atlas(mtcars, "mpg", constraints = cons)
#' }
#' @export
extract_constraints <- function(text, data = NULL, chat = NULL) {
  chat <- chat %||% ellmer::chat_anthropic()
  spec <- chat$chat_structured(
    paste0(
      "Extract every modeling constraint from the brief below.\n",
      "Constraint types:\n",
      "- uses: a specific variable must be used in the model\n",
      "- monotone: predictions must be monotone in a variable\n",
      "- other: any other rule (restate it clearly and completely)\n",
      if (!is.null(data)) {
        paste0("Available columns: ", paste(names(data), collapse = ", "),
               ". `variable` must be exactly one of these.\n")
      },
      "\nBrief:\n", text
    ),
    type = ellmer::type_array(
      ellmer::type_object(
        name = ellmer::type_string("short snake_case identifier"),
        type = ellmer::type_enum(c("uses", "monotone", "other")),
        variable = ellmer::type_string(
          "exact column name, for uses/monotone", required = FALSE),
        direction = ellmer::type_enum(
          c("increasing", "decreasing"), "for monotone", required = FALSE),
        description = ellmer::type_string("the rule restated in one sentence")
      ),
      "one entry per constraint found"
    )
  )
  constraints_from_spec(spec, data)
}

# Pure spec -> constraints step, kept separate from the LLM call so it can
# be tested offline. `spec` is a data.frame(name, type, variable, direction,
# description) as returned by the structured extraction.
constraints_from_spec <- function(spec, data = NULL) {
  if (NROW(spec) == 0) return(list())
  out <- list()
  nms <- character()
  for (i in seq_len(NROW(spec))) {
    row <- spec[i, ]
    var <- row$variable
    var_ok <- !is.null(var) && !is.na(var) && nzchar(var) &&
      (is.null(data) || var %in% names(data))
    out[[i]] <- if (identical(row$type, "uses") && var_ok) {
      con_uses(var)
    } else if (identical(row$type, "monotone") && var_ok &&
               !is.na(row$direction)) {
      con_monotone(var, row$direction)
    } else {
      constraint(row$description)
    }
    nms[[i]] <- if (is.na(row$name) || !nzchar(row$name)) "" else row$name
  }
  names(out) <- make.unique(nms, sep = "_")
  normalize_constraints(out)
}

#' @export
format.atlas_constraint <- function(x, ...) {
  paste0(if (is.null(x$check)) "[prompt-only]     " else "[machine-checked] ",
         x$description)
}

#' @export
print.atlas_constraint <- function(x, ...) {
  cat(format(x), "\n", sep = "")
  invisible(x)
}

# Accept NULL, a string, a constraint, or a (possibly named) list of either;
# return a named list of atlas_constraint.
normalize_constraints <- function(x) {
  if (is.null(x)) return(list())
  if (inherits(x, "atlas_constraint")) {
    x <- list(x)          # a bare constraint: wrap, don't explode its fields
  } else if (!is.list(x)) {
    x <- as.list(x)       # character vector -> list of strings
  }
  x <- lapply(x, function(ci) {
    if (inherits(ci, "atlas_constraint")) ci else constraint(as.character(ci))
  })
  nm <- names(x)
  if (is.null(nm)) nm <- rep("", length(x))
  names(x) <- ifelse(nm == "", paste0("constraint_", seq_along(x)), nm)
  x
}

# Run every machine check against every model.
# Returns data.frame(model, constraint, passed, detail); prompt-only
# constraints appear once with passed = NA so they stay visible.
verify_constraints <- function(constraints, models, data) {
  rows <- list()
  for (cn in names(constraints)) {
    cons <- constraints[[cn]]
    if (is.null(cons$check)) {
      rows[[length(rows) + 1]] <- data.frame(
        model = "(all)", constraint = cn, passed = NA,
        detail = "no machine check; enforced via instructions")
      next
    }
    for (mn in names(models)) {
      out <- tryCatch(cons$check(models[[mn]], data),
                      error = function(e) paste("check errored:", conditionMessage(e)))
      rows[[length(rows) + 1]] <- data.frame(
        model = mn, constraint = cn, passed = isTRUE(out),
        detail = if (is.character(out)) out else "")
    }
  }
  if (!length(rows)) {
    return(data.frame(model = character(), constraint = character(),
                      passed = logical(), detail = character()))
  }
  do.call(rbind, rows)
}
