# Send a message to a running atlas session

Steer a build that is already underway - even a fully autonomous one -
from any other R session or terminal. The message is written to the run
directory and delivered to the agent with its next tool result, marked
as its highest-priority instruction: "focus on gradient boosting", "stop
engineering interactions and tune the winner", "drop CREDIT_GRADE, it is
not available in deployment".

## Usage

``` r
atlas_message(dir, text)
```

## Arguments

- dir:

  The run directory of the session to steer.

- text:

  What to tell the agent.

## Value

`dir`, invisibly.

## Details

Delivery happens at the agent's next code execution, so a message lands
within one step; one sent after the run finishes is simply never picked
up (use
[`atlas_resume()`](https://mattyoreilly.github.io/Atlas/reference/atlas_resume.md)
and `$tell()` instead).

## Examples

``` r
if (FALSE) { # \dontrun{
# terminal 1: an unattended experiment loop
atlas(claims, "severity", autonomous = TRUE, test_prop = 0.2,
      dir = "~/runs/severity")

# terminal 2, twenty minutes later:
atlas_message("~/runs/severity",
              "focus on the gamma GLM family; stop trying trees")
} # }
```
