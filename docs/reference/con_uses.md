# Constraint: the model must use a given variable

Machine-checked and model-agnostic: the check shuffles (reverses) the
column and compares predictions; if they don't move, the model isn't
using the variable. Works for any model that supports
`predict(model, newdata = <data.frame>)`.

## Usage

``` r
con_uses(var)
```

## Arguments

- var:

  Column name that must contribute to predictions.

## Value

An `atlas_constraint`.

## Examples

``` r
# the check itself needs no LLM: it works on any fitted model
uses_wt <- con_uses("wt")
uses_wt$check(lm(mpg ~ wt + hp, mtcars), mtcars)  # TRUE
#> [1] TRUE
uses_wt$check(lm(mpg ~ hp, mtcars), mtcars)       # a violation message
#> [1] "predictions are unchanged when `wt` is scrambled - the model does not use it"

if (FALSE) { # \dontrun{
atlas(mtcars, "mpg", constraints = list(uses_wt = con_uses("wt")))
} # }
```
