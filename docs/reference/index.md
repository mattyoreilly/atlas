# Package index

## Build models

The main entry point, the session object behind it, and how to pick a
run back up.

- [`atlas()`](https://mattyoreilly.github.io/Atlas/reference/atlas.md) :
  Build models automatically with an LLM agent
- [`atlas_session`](https://mattyoreilly.github.io/Atlas/reference/atlas_session.md)
  : A persistent, resumable model-building session
- [`atlas_resume()`](https://mattyoreilly.github.io/Atlas/reference/atlas_resume.md)
  : Resume a session from its run directory
- [`atlas_message()`](https://mattyoreilly.github.io/Atlas/reference/atlas_message.md)
  : Send a message to a running atlas session

## Domain knowledge

Hard requirements the models must satisfy - verified by atlas itself,
not trusted to the agent.

- [`constraint()`](https://mattyoreilly.github.io/Atlas/reference/constraint.md)
  : Define a hard constraint on the models Atlas builds
- [`con_uses()`](https://mattyoreilly.github.io/Atlas/reference/con_uses.md)
  : Constraint: the model must use a given variable
- [`con_monotone()`](https://mattyoreilly.github.io/Atlas/reference/con_monotone.md)
  : Constraint: predictions must be monotonic in a variable
- [`extract_constraints()`](https://mattyoreilly.github.io/Atlas/reference/extract_constraints.md)
  : Extract constraints from a natural-language brief

## Feature safety

Catching target leakage before it reaches a model.

- [`atlas_leakage_screen()`](https://mattyoreilly.github.io/Atlas/reference/atlas_leakage_screen.md)
  : Screen predictors for possible target leakage

## Point-and-click

The browser front-end for non-programmers.

- [`atlas_app()`](https://mattyoreilly.github.io/Atlas/reference/atlas_app.md)
  : Launch the Atlas point-and-click app
