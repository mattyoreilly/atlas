#' Launch the Atlas point-and-click app
#'
#' A browser UI for people who don't write R: upload a CSV, choose what to
#' predict, optionally describe goals and rules in plain English, and click
#' Build. Progress streams live; when the agent needs a decision, a dialog
#' pops up. Results (leaderboard, constraint compliance, report, and the full
#' R code) appear when the build finishes, and everything is also saved to
#' the run directory as usual.
#'
#' The build runs in a background R process (via `callr`), so the app stays
#' responsive; the agent's questions travel through small files in the run
#' directory. Requires the `shiny` and `callr` packages and an API key for
#' your LLM provider (see `vignette("atlas")`).
#'
#' @param max_upload_mb Maximum size of an uploaded CSV, in megabytes.
#'   (Shiny's own default is a stingy 5 MB.)
#' @return Called for its side effect (runs the app until you close it).
#' @examples
#' \dontrun{
#' atlas_app()
#' atlas_app(max_upload_mb = 2000)  # roomier limit for big files
#' }
#' @export
atlas_app <- function(max_upload_mb = 500) {
  for (pkg in c("shiny", "callr", "bslib")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop("atlas_app() needs the '", pkg, "' package; install it with ",
           'install.packages("', pkg, '")', call. = FALSE)
    }
  }
  old <- options(shiny.maxRequestSize = max_upload_mb * 1024^2)
  on.exit(options(old))
  shiny::runApp(shiny::shinyApp(atlas_app_ui(), atlas_app_server))
}

atlas_app_ui <- function() {
  bslib::page_sidebar(
    title = "Atlas",
    fillable = FALSE,  # let the page scroll; fillable squishes result tables
    theme = bslib::bs_theme(version = 5, bootswatch = "zephyr"),
    sidebar = bslib::sidebar(
      width = 360,
      bslib::accordion(
        multiple = TRUE,
        open = c("Your data", "What to build"),
        bslib::accordion_panel(
          "Your data",
          shiny::fileInput("file", "Upload a CSV file",
                           accept = c(".csv", "text/csv")),
          shiny::checkboxInput("demo", "No data handy? Try the example (mtcars)"),
          shiny::selectInput("outcome", "What do you want to predict?",
                             choices = NULL),
          shiny::uiOutput("features_ui")
        ),
        bslib::accordion_panel(
          "What to build",
          shiny::numericInput("n_models", "Maximum number of models",
                              value = 3, min = 1, max = 6),
          shiny::textAreaInput(
            "goal", "What matters to you? (optional)", rows = 2,
            placeholder = "e.g. I need to explain the model to my boss"),
          shiny::textAreaInput(
            "rules", "Rules the models must follow (optional, plain English)",
            rows = 3,
            placeholder = paste("e.g. weight must be used;",
                                "predictions must never go up as horsepower rises"))
        ),
        bslib::accordion_panel(
          "When to stop",
          shiny::numericInput(
            "stopping_rounds", "Attempts in a row without improvement",
            value = 3, min = 1, max = 10, step = 1),
          shiny::numericInput(
            "stopping_tolerance", "Smallest improvement that counts (0.05 = 5%)",
            value = 0.05, min = 0, max = 1, step = 0.01)
        )
      ),
      shiny::textInput(
        "outdir", "Save results to",
        value = getOption("atlas.dir", ".atlas"),
        placeholder = "e.g. ~/atlas-runs"),
      shiny::actionButton("browse_dir", "Browse...",
                          class = "btn-sm btn-outline-secondary mb-3"),
      bslib::input_task_button("build", "Build models"),
      shiny::uiOutput("interject_ui"),
      shiny::uiOutput("refine_ui"),
      shiny::helpText("Your data never leaves this computer; the AI only",
                      "sees column names and summaries.")
    ),
    shiny::tags$style(shiny::HTML(
      "#logbox { max-height: 75vh; overflow-y: auto; }
       #logbox pre, .atlas-report pre {
         background: var(--bs-tertiary-bg, #f6f8fa);
         border: 1px solid var(--bs-border-color, #e1e4e8);
         border-radius: 6px; padding: 10px; white-space: pre-wrap; }
       #logbox blockquote { border-left: 4px solid var(--bs-primary);
                            padding-left: 10px;
                            color: var(--bs-secondary-color); }
       .atlas-report { max-width: 75ch; }
       .atlas-report h1 { font-size: 1.4em; }
       .atlas-report h2 { font-size: 1.25em; }
       .atlas-report h3 { font-size: 1.1em; }
       #logbox table, .atlas-report table {
         border-collapse: collapse; margin: 10px 0;
         display: block; overflow-x: auto; max-width: 100%;
         white-space: nowrap; }
       #logbox th, #logbox td, .atlas-report th, .atlas-report td {
         border: 1px solid var(--bs-border-color, #e1e4e8);
         padding: 4px 12px; text-align: left; }
       #logbox th, .atlas-report th {
         background: var(--bs-tertiary-bg, #f6f8fa); }")),
    shiny::tags$script(shiny::HTML(
      "$(document).on('shiny:value', function(e) {
         if (e.name === 'log_html') {
           var el = document.getElementById('logbox');
           if (el) setTimeout(function() {
             el.scrollTop = el.scrollHeight; }, 100);
         }
       });")),
    bslib::navset_card_underline(
      id = "tabs",
      bslib::nav_panel(
        "Progress",
        shiny::tags$div(id = "logbox", shiny::uiOutput("log_html"))),
      bslib::nav_panel("Results", shiny::uiOutput("results_ui")),
      bslib::nav_panel(
        "R code",
        shiny::helpText("Everything the agent ran - a reproducible script."),
        shiny::verbatimTextOutput("code"))
    )
  )
}

atlas_app_server <- function(input, output, session) {
  state <- shiny::reactiveValues(proc = NULL, dir = NULL, log = "",
                                 done = FALSE, modal_open = FALSE)

  data_r <- shiny::reactive({
    if (isTRUE(input$demo)) return(datasets::mtcars)
    shiny::req(input$file)
    utils::read.csv(input$file$datapath)
  })

  shiny::observe({
    df <- data_r()
    shiny::updateSelectInput(session, "outcome", choices = names(df))
  })

  # feature picker: untick anything unavailable at prediction time; columns
  # that alone explain ~all of the outcome get a leakage warning
  output$features_ui <- shiny::renderUI({
    df <- data_r()
    shiny::req(df, input$outcome %in% names(df))
    predictors <- setdiff(names(df), input$outcome)
    screen <- tryCatch(atlas_leakage_screen(df, input$outcome),
                       error = function(e) NULL)
    labels <- lapply(predictors, function(v) {
      r2 <- if (!is.null(screen)) screen$r2[screen$variable == v]
      if (!is.null(screen) && isTRUE(screen$flagged[screen$variable == v])) {
        shiny::tags$span(
          v, shiny::tags$strong(sprintf(" - possible leakage (R2 %.2f)", r2),
                                style = "color: var(--bs-danger);"))
      } else {
        v
      }
    })
    shiny::tags$div(
      style = "max-height: 260px; overflow-y: auto;",
      shiny::checkboxGroupInput(
        "features", "Columns usable at prediction time (untick to exclude)",
        choiceNames = labels, choiceValues = predictors,
        selected = predictors)
    )
  })

  # native folder picker: RStudio's dialog when its API has one, else the
  # Tcl/Tk chooser that ships with base R, else type the path
  shiny::observeEvent(input$browse_dir, {
    path <- NULL
    if (requireNamespace("rstudioapi", quietly = TRUE) &&
        rstudioapi::isAvailable() &&
        rstudioapi::hasFun("selectDirectory")) {
      path <- rstudioapi::selectDirectory(
        caption = "Choose where to save Atlas results",
        path = path.expand(getOption("atlas.dir", "~")))
    } else if (capabilities("tcltk") &&
               requireNamespace("tcltk", quietly = TRUE)) {
      path <- tryCatch(
        tcltk::tk_choose.dir(default = path.expand("~"),
                             caption = "Choose where to save Atlas results"),
        error = function(e) NULL)
    } else {
      shiny::showNotification(
        "No folder picker is available here - type the path instead.",
        type = "warning")
    }
    if (!is.null(path) && !is.na(path) && nzchar(path)) {
      shiny::updateTextInput(session, "outdir", value = path)
    }
  })

  shiny::observeEvent(input$build, {
    df <- tryCatch(data_r(), error = function(e) NULL)
    if (is.null(df) || !nzchar(input$outcome %||% "")) {
      shiny::showNotification(
        "Upload a CSV (or tick the example) and choose what to predict first.",
        type = "warning")
      bslib::update_task_button("build", state = "ready")
      return()
    }
    if (!is.null(state$proc) && state$proc$is_alive()) {
      shiny::showNotification("A build is already running.", type = "warning")
      bslib::update_task_button("build", state = "ready")
      return()
    }
    base <- trimws(input$outdir %||% "")
    if (!nzchar(base)) base <- getOption("atlas.dir", ".atlas")
    dir <- file.path(path.expand(base), format(Sys.time(), "%Y%m%d-%H%M%S"))
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    if (!dir.exists(dir)) {
      shiny::showNotification(
        paste("Can't create folder", dir, "- check the 'Save results to' path."),
        type = "error")
      bslib::update_task_button("build", state = "ready")
      return()
    }
    saveRDS(df, file.path(dir, "upload.rds"))
    state$dir <- dir
    state$log <- ""
    state$done <- FALSE
    state$proc <- callr::r_bg(
      atlas_app_worker,
      args = list(dir = dir, outcome = input$outcome,
                  n_models = input$n_models, goal = input$goal,
                  rules = input$rules, stopping_rounds = input$stopping_rounds,
                  stopping_tolerance = input$stopping_tolerance,
                  exclude = setdiff(setdiff(names(df), input$outcome),
                                    input$features)),
      stdout = "|", stderr = "2>&1"
    )
    bslib::nav_select("tabs", "Progress")
  })

  # interrupt a RUNNING build: the message lands in the run dir and reaches
  # the agent with its next tool result
  output$interject_ui <- shiny::renderUI({
    shiny::req(!state$done, !is.null(state$proc))
    shiny::tagList(
      shiny::hr(),
      shiny::textAreaInput(
        "interject", "Steer the build (reaches Atlas at its next step)",
        rows = 2,
        placeholder = paste("e.g. focus on improving calibration; change",
                            "the feature engineering for income; drop",
                            "CREDIT_GRADE, it isn't available in deployment")),
      shiny::actionButton("send_interject", "Send now",
                          class = "btn-warning btn-sm")
    )
  })

  shiny::observeEvent(input$send_interject, {
    msg <- trimws(input$interject %||% "")
    shiny::req(nzchar(msg), state$dir)
    writeLines(msg, file.path(state$dir, "interject.txt"))
    shiny::updateTextAreaInput(session, "interject", value = "")
    shiny::showNotification(
      "Message sent - Atlas will see it at its next step.", type = "message")
  })

  # follow-up instructions once a build has finished: resume the session in a
  # fresh background process and hand it the new prompt
  output$refine_ui <- shiny::renderUI({
    shiny::req(state$done)
    shiny::tagList(
      shiny::hr(),
      shiny::textAreaInput(
        "refine", "Ask for more", rows = 3,
        placeholder = paste("e.g. take the best model and refine its feature",
                            "engineering until it stops improving")),
      bslib::input_task_button("send_refine", "Send to Atlas")
    )
  })

  shiny::observeEvent(input$send_refine, {
    if (!nzchar(trimws(input$refine %||% "")) || is.null(state$dir)) {
      bslib::update_task_button("send_refine", state = "ready")
      return()
    }
    state$done <- FALSE
    state$log <- paste0(state$log, "\n\n---\n\n> **You asked:** ",
                        input$refine, "\n\n")
    state$proc <- callr::r_bg(
      atlas_app_worker,
      args = list(dir = state$dir, instruction = input$refine),
      stdout = "|", stderr = "2>&1"
    )
    bslib::nav_select("tabs", "Progress")
  })

  # poll the background build: stream output, relay questions, detect the end
  shiny::observe({
    proc <- state$proc
    if (is.null(proc) || state$done) return()
    shiny::invalidateLater(700)

    chunk <- proc$read_output()
    if (nzchar(chunk)) state$log <- paste0(state$log, chunk)

    qf <- file.path(state$dir, "question.txt")
    af <- file.path(state$dir, "answer.txt")
    if (file.exists(qf) && !file.exists(af) && !state$modal_open) {
      state$modal_open <- TRUE
      shiny::showModal(shiny::modalDialog(
        title = "Atlas needs your approval or input",
        shiny::tags$pre(paste(readLines(qf, warn = FALSE), collapse = "\n"),
                        style = "white-space: pre-wrap;"),
        shiny::textAreaInput(
          "answer", NULL, rows = 3, width = "100%",
          placeholder = paste(
            "Approve, or steer it - e.g. 'yes, go ahead', or 'drop the",
            "tree model, add an income x loan-term interaction, and focus",
            "on calibration'")),
        footer = shiny::actionButton("send_answer", "Send"),
        size = "l",
        easyClose = FALSE
      ))
    }

    if (!proc$is_alive()) {
      state$log <- paste0(state$log, proc$read_all_output(),
                          "\n\n**Build finished.**\n")
      state$done <- TRUE
      # an unread interjection can't reach a finished build
      leftover <- file.path(state$dir, "interject.txt")
      if (file.exists(leftover)) {
        file.remove(leftover)
        shiny::showNotification(
          paste("Your last message arrived after the build finished -",
                "send it with 'Ask for more' instead."), type = "warning")
      }
      bslib::update_task_button("build", state = "ready")
      bslib::update_task_button("send_refine", state = "ready")
      bslib::nav_select("tabs", "Results")
    }
  })

  shiny::observeEvent(input$send_answer, {
    writeLines(input$answer %||% "", file.path(state$dir, "answer.txt"))
    state$modal_open <- FALSE
    shiny::removeModal()
  })

  run_file <- function(name) {
    if (!state$done || is.null(state$dir)) return(NULL)
    path <- file.path(state$dir, name)
    if (file.exists(path)) path else NULL
  }

  output$log_html <- shiny::renderUI({
    txt <- gsub("\033\\[[0-9;]*m", "", state$log)  # strip stray ANSI colours
    if (!nzchar(txt)) {
      return(shiny::helpText("Progress will appear here once you click Build."))
    }
    if (requireNamespace("commonmark", quietly = TRUE)) {
      # extensions = TRUE enables GFM pipe tables; off, they render as text
      shiny::HTML(commonmark::markdown_html(txt, extensions = TRUE))
    } else {
      shiny::tags$pre(txt, style = "white-space: pre-wrap;")
    }
  })

  output$results_ui <- shiny::renderUI({
    if (!state$done) {
      return(shiny::helpText("Results appear here when a build finishes."))
    }
    lb_path <- run_file("leaderboard.csv")
    lb <- if (!is.null(lb_path)) utils::read.csv(lb_path)
    cdf <- constraints_df()
    checked <- if (is.null(cdf)) cdf else cdf[!is.na(cdf$passed), , drop = FALSE]

    shiny::tagList(
      bslib::layout_column_wrap(
        width = 1 / 3, fill = FALSE, class = "mb-3",
        bslib::value_box(
          title = "Best model", theme = "primary",
          value = if (!is.null(lb) && nrow(lb) > 0) lb$name[1] else "none",
          shiny::p(if (!is.null(lb) && nrow(lb) > 0) {
            sprintf("%s: %s", lb$metric[1], format(lb$value[1], digits = 3))
          } else {
            "no leaderboard produced"
          })
        ),
        bslib::value_box(
          title = "Models built", theme = "secondary",
          value = if (is.null(lb)) 0L else nrow(lb)
        ),
        bslib::value_box(
          title = "Rules",
          theme = if (is.null(checked) || nrow(checked) == 0) "secondary"
                  else if (all(checked$passed)) "success" else "danger",
          value = if (is.null(checked) || nrow(checked) == 0) "none set"
                  else sprintf("%d/%d passed", sum(checked$passed), nrow(checked))
        )
      ),
      bslib::card(
        bslib::card_header("Leaderboard"),
        if (is.null(lb)) {
          shiny::helpText("No leaderboard was produced - see Progress for why.")
        } else {
          shiny::tableOutput("leaderboard")
        }
      ),
      shiny::uiOutput("constraints_ui"),
      local({
        html_files <- list.files(state$dir, pattern = "\\.html$",
                                 recursive = TRUE)
        if (length(html_files) == 0) return(NULL)
        shiny::addResourcePath("atlasrun", normalizePath(state$dir))
        bslib::card(
          bslib::card_header("Validation plots (interactive)"),
          shiny::tags$ul(lapply(html_files, function(f) {
            shiny::tags$li(shiny::tags$a(href = file.path("atlasrun", f),
                                         target = "_blank", basename(f)))
          }))
        )
      }),
      bslib::card(
        bslib::card_header("Report"),
        shiny::tags$div(class = "atlas-report", shiny::uiOutput("report"))
      )
    )
  })

  output$leaderboard <- shiny::renderTable({
    path <- run_file("leaderboard.csv")
    shiny::req(path)
    utils::read.csv(path)
  }, striped = TRUE, hover = TRUE, digits = 3, na = "")

  constraints_df <- shiny::reactive({
    shiny::req(state$done, state$dir)
    atlas_load_results(state$dir)
  })

  output$constraints_ui <- shiny::renderUI({
    df <- constraints_df()
    if (is.null(df) || nrow(df) == 0) return(NULL)
    bslib::card(bslib::card_header("Rules check"),
                shiny::tableOutput("constraints_tbl"))
  })

  output$constraints_tbl <- shiny::renderTable({
    df <- constraints_df()
    df$passed <- ifelse(is.na(df$passed), "not checked",
                        ifelse(df$passed, "PASS", "FAIL"))
    names(df) <- c("model", "rule", "result", "detail")
    df
  }, striped = TRUE, hover = TRUE, na = "")

  output$report <- shiny::renderUI({
    path <- run_file("report.md")
    if (is.null(path)) {
      return(shiny::helpText("No report was produced."))
    }
    txt <- paste(readLines(path, warn = FALSE), collapse = "\n")
    if (requireNamespace("commonmark", quietly = TRUE)) {
      # extensions = TRUE enables GFM pipe tables; off, they render as text
      shiny::HTML(commonmark::markdown_html(txt, extensions = TRUE))
    } else {
      shiny::tags$pre(txt, style = "white-space: pre-wrap;")
    }
  })

  output$code <- shiny::renderText({
    path <- run_file("code.R")
    shiny::req(path)
    paste(readLines(path, warn = FALSE), collapse = "\n")
  })
}

# Re-verify constraints from a finished run directory (models + meta on disk).
atlas_load_results <- function(dir) {
  models_path <- file.path(dir, "models.rds")
  if (!file.exists(models_path)) return(NULL)
  verify_constraints(readRDS(file.path(dir, "meta.rds"))$constraints,
                     readRDS(models_path),
                     readRDS(file.path(dir, "data.rds")))
}

# Runs in a background R process. callr strips the namespace from the
# function it transports, so every Atlas call in here must be :: qualified.
# Questions travel via question.txt/answer.txt in the run dir; progress via
# stdout, which the app tails. With `instruction` set it resumes the existing
# session and sends a follow-up instead of starting a fresh build.
atlas_app_worker <- function(dir, outcome = NULL, n_models = 3, goal = NULL,
                             rules = NULL, stopping_rounds = 3, stopping_tolerance = 0.05,
                             exclude = NULL, instruction = NULL) {
  ask_via_files <- function(question) {
    qf <- file.path(dir, "question.txt")
    af <- file.path(dir, "answer.txt")
    cat("\n> **Atlas asks:** ", gsub("\n", "\n> ", question), "\n\n", sep = "")
    writeLines(question, qf)
    while (!file.exists(af)) Sys.sleep(0.5)
    ans <- paste(readLines(af, warn = FALSE), collapse = "\n")
    file.remove(qf, af)
    cat("> **You answered:** ", ans, "\n\n", sep = "")
    ans
  }
  interject_via_files <- function() {
    f <- file.path(dir, "interject.txt")
    if (!file.exists(f)) return(NULL)
    msg <- paste(readLines(f, warn = FALSE), collapse = "\n")
    file.remove(f)
    msg
  }

  if (!is.null(instruction)) {
    cat("Restoring your session (re-running the recorded code)...\n\n")
    s <- atlas::atlas_resume(dir, on_ask = ask_via_files,
                             display = "markdown",
                             interject = interject_via_files)
    s$tell(instruction, verbose = TRUE)
    return(invisible(NULL))
  }

  data <- readRDS(file.path(dir, "upload.rds"))
  goal <- if (nzchar(trimws(goal %||% ""))) goal
  cons <- NULL
  if (nzchar(trimws(rules %||% ""))) {
    cat("Turning your rules into constraints...\n\n")
    cons <- atlas::extract_constraints(rules, data[setdiff(names(data), exclude)])
    for (nm in names(cons)) {
      cat("* `", format(cons[[nm]]), "`\n", sep = "")
    }
    cat("\n")
  }
  if (length(exclude) > 0) {
    cat("Excluded from modelling (your choice): ",
        paste0("`", exclude, "`", collapse = ", "), "\n\n", sep = "")
  }
  s <- atlas::atlas_session$new(data, outcome, n_models = n_models, goal = goal,
                               constraints = cons, dir = dir,
                               on_ask = ask_via_files, display = "markdown",
                               stopping_rounds = stopping_rounds, stopping_tolerance = stopping_tolerance,
                               exclude = exclude,
                               interject = interject_via_files)
  s$build(verbose = TRUE)
  invisible(NULL)
}
