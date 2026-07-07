# Screen predictors for possible target leakage

A quick, model-free screen: for each predictor, how much of the outcome
does it explain on its own (R-squared of `lm(outcome ~ predictor)`, with
factor outcomes coded to integers)? Near-perfect univariate fits usually
mean the column is derived from the outcome or recorded after it -
classic leakage. Used automatically by
[`atlas()`](https://mattyoreilly.github.io/Atlas/reference/atlas.md) to
warn the agent, and by
[`atlas_app()`](https://mattyoreilly.github.io/Atlas/reference/atlas_app.md)
to flag columns in the feature picker; also useful on its own before any
modeling.

## Usage

``` r
atlas_leakage_screen(data, outcome, threshold = 0.95, max_rows = 5000)
```

## Arguments

- data:

  A data.frame.

- outcome:

  Name of the outcome column.

- threshold:

  Flag predictors with univariate R-squared at or above this value.

- max_rows:

  Screen at most this many rows (evenly spaced) for speed.

## Value

A data.frame with `variable`, `r2`, and `flagged`. High-cardinality
factors (e.g. IDs) get `r2 = NA`: they can't be assessed this way, but
are usually unusable as predictors anyway.

## Examples

``` r
leaky <- mtcars
leaky$mpg_copy <- leaky$mpg * 2
atlas_leakage_screen(leaky, "mpg")
#>    variable     r2 flagged
#> 1       cyl 0.7262   FALSE
#> 2      disp 0.7183   FALSE
#> 3        hp 0.6024   FALSE
#> 4      drat 0.4640   FALSE
#> 5        wt 0.7528   FALSE
#> 6      qsec 0.1753   FALSE
#> 7        vs 0.4409   FALSE
#> 8        am 0.3598   FALSE
#> 9      gear 0.2307   FALSE
#> 10     carb 0.3035   FALSE
#> 11 mpg_copy 1.0000    TRUE
```
