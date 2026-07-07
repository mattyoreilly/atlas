# Shared test doubles and constructors, loaded by testthat before the tests.

# A scripted stand-in for an ellmer Chat, so the full agentic loop can run
# offline. Each script step says what the "agent" does when it receives one
# message: which registered tools it calls (in order, with arguments) and the
# text it replies with. Messages beyond the script are an error - tests
# should know exactly how many turns they expect.
FakeChat <- R6::R6Class("FakeChat",
  public = list(
    log = character(),        # every prompt received, in order
    context_tokens = 0,       # settable: pretend context size for get_tokens
    turns_cleared = 0L,       # how many times set_turns() wiped the window

    initialize = function(script = list()) private$script <- script,
    get_tokens = function() data.frame(input = self$context_tokens),
    get_cost = function(include = "all") 0.0123,
    set_system_prompt = function(x) private$sys <- x,
    get_system_prompt = function() private$sys,
    register_tool = function(t) private$tools[[t@name]] <- t,
    get_tools = function() private$tools,
    get_turns = function() as.list(self$log),
    set_turns = function(turns) {
      if (length(turns) == 0) self$turns_cleared <- self$turns_cleared + 1L
      invisible(turns)
    },
    chat = function(text, echo = "none") private$step(text),
    stream = function(text, ...) {
      reply <- private$step(text)
      sent <- FALSE
      function() {
        if (sent) return(coro::exhausted())
        sent <<- TRUE
        reply
      }
    }
  ),
  private = list(
    script = NULL,
    tools = list(),
    sys = NULL,
    step = function(text) {
      self$log <- c(self$log, text)
      i <- length(self$log)
      if (i > length(private$script)) stop("FakeChat script exhausted")
      s <- private$script[[i]]
      for (cl in s$calls %||% list()) {
        do.call(private$tools[[cl$tool]], cl$args)
      }
      s$reply %||% "ok"
    }
  )
)

# A real ellmer chat that never makes a request; the key only satisfies the
# constructor. For tests of everything except the chat loop itself.
real_chat <- function() {
  if (Sys.getenv("ANTHROPIC_API_KEY") == "") {
    Sys.setenv(ANTHROPIC_API_KEY = "test-key-no-network")
  }
  ellmer::chat_anthropic()
}

temp_dir <- function() {
  file.path(tempdir(), paste0("atlas-", as.integer(stats::runif(1, 1, 1e9))))
}

new_session <- function(dir = temp_dir(), chat = real_chat(), ...) {
  atlas_session$new(mtcars, "mpg", n_models = 2, goal = "keep it simple",
                   chat = chat, dir = dir, ...)
}
