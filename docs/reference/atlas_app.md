# Launch the Atlas point-and-click app

A browser UI for people who don't write R: upload a CSV, choose what to
predict, optionally describe goals and rules in plain English, and click
Build. Progress streams live; when the agent needs a decision, a dialog
pops up. Results (leaderboard, constraint compliance, report, and the
full R code) appear when the build finishes, and everything is also
saved to the run directory as usual.

## Usage

``` r
atlas_app(max_upload_mb = 500)
```

## Arguments

- max_upload_mb:

  Maximum size of an uploaded CSV, in megabytes. (Shiny's own default is
  a stingy 5 MB.)

## Value

Called for its side effect (runs the app until you close it).

## Details

The build runs in a background R process (via `callr`), so the app stays
responsive; the agent's questions travel through small files in the run
directory. Requires the `shiny` and `callr` packages and an API key for
your LLM provider (see
[`vignette("atlas")`](https://mattyoreilly.github.io/Atlas/articles/atlas.md)).

## Examples

``` r
if (FALSE) { # \dontrun{
atlas_app()
atlas_app(max_upload_mb = 2000)  # roomier limit for big files
} # }
```
