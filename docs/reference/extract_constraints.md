# Extract constraints from a natural-language brief

Uses the LLM to parse free text into Atlas constraints, mapping to
machine-checked types wherever possible: "wt must be used" becomes
[`con_uses()`](https://mattyoreilly.github.io/Atlas/reference/con_uses.md),
"mpg should never increase with weight" becomes
[`con_monotone()`](https://mattyoreilly.github.io/Atlas/reference/con_monotone.md),
and anything else becomes a prompt-enforced
[`constraint()`](https://mattyoreilly.github.io/Atlas/reference/constraint.md).
Returns the list for you to inspect (print it!) before passing to
[`atlas()`](https://mattyoreilly.github.io/Atlas/reference/atlas.md) —
the parse is a judgment call, so review it.

## Usage

``` r
extract_constraints(text, data = NULL, chat = NULL)
```

## Arguments

- text:

  The brief, in plain language. Sentences, bullets, whatever.

- data:

  Optional data.frame the constraints are about; its column names are
  given to the parser, and extracted variable names are validated
  against them (a constraint naming an unknown column falls back to
  prompt-only enforcement).

- chat:

  An ellmer chat object; defaults to
  [`ellmer::chat_anthropic()`](https://ellmer.tidyverse.org/reference/chat_anthropic.html).

## Value

A named list of
[`constraint()`](https://mattyoreilly.github.io/Atlas/reference/constraint.md)
objects, ready for the `constraints` argument of
[`atlas()`](https://mattyoreilly.github.io/Atlas/reference/atlas.md) or
[atlas_session](https://mattyoreilly.github.io/Atlas/reference/atlas_session.md).

## Examples

``` r
if (FALSE) { # \dontrun{
cons <- extract_constraints(
  "weight must be in the model; predictions can never go up as
   horsepower rises; qsec is post-hoc, never use it",
  data = mtcars
)
cons  # inspect: which became machine checks?
res <- atlas(mtcars, "mpg", constraints = cons)
} # }
```
