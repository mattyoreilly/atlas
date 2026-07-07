# Resume a session from its run directory

Rebuilds an
[atlas_session](https://mattyoreilly.github.io/Atlas/reference/atlas_session.md)
after a crash or R restart: reloads the data, replays every recorded
code chunk to reconstruct the working environment (models included), and
restores the conversation so the agent remembers everything it did.

## Usage

``` r
atlas_resume(dir, chat = NULL, ...)
```

## Arguments

- dir:

  A run directory created by a previous session.

- chat:

  Optionally a fresh ellmer chat object (must be tool-capable); defaults
  to
  [`ellmer::chat_anthropic()`](https://ellmer.tidyverse.org/reference/chat_anthropic.html).

- ...:

  Passed on to the
  [atlas_session](https://mattyoreilly.github.io/Atlas/reference/atlas_session.md)
  constructor, e.g. `on_ask` or `display` when resuming inside a
  front-end.

## Value

An
[atlas_session](https://mattyoreilly.github.io/Atlas/reference/atlas_session.md).

## Examples

``` r
if (FALSE) { # \dontrun{
s <- atlas_resume(".atlas/20260703-141500")
s$tell("continue where you left off")
} # }
```
