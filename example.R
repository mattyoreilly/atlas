# atlas test drive ------------------------------------------------------
#
# One-time setup:
#   1. install this branch:
#        pak::local_install(".")   # from the package directory
#        # or: remotes::install_github("mattyoreilly/Atlas",
#        #                             ref = "feature/live-tally-steering")
#   2. API key (once, then restart R):
#        usethis::edit_r_environ()   # add: ANTHROPIC_API_KEY=sk-ant-...

library(atlas)

# 1. Load your data ------------------------------------------------------
csv_path <- "~/Desktop/Hastings/HastingsCredit/Data/app_approved_train.csv"
outcome <- "DEFAULTED" # <- edit me: the column to predict

data <- read.csv(csv_path, stringsAsFactors = TRUE)
str(data, list.len = 25)

# 2. Pre-flight ----------------------------------------------------------
# Which columns look like target leakage on their own?
atlas_leakage_screen(data, outcome)

# Columns that won't exist at prediction time in deployment (IDs,
# post-outcome fields, decline reasons...) - they are removed before the
# agent ever sees the data:
exclude <- c("default_rate", "Total_Loan_Amount", "PREDICTED_LOSS", "APR") # <- e.g. c("QUOTE_DECLINE_REASON")

# 3. Interactive build ----------------------------------------------------
# The agent explores, proposes a plan, and STOPS IN THE CONSOLE for your
# approval - answer "yes", or steer it ("only GLMs, no trees").
# Watch for the live tally lines as models and tweaks are scored:
#   [tally #4 | gbm1: auc = 0.81 | best: glm2 = 0.79 | flat: 0/3 -> KEEP]
res <- atlas(
  data,
  outcome,
  n_models = 1, # maximum candidates
  goal = "prioritise interpretability",
  exclude = exclude,
  test_prop = 0.2, # held out; agent never sees these rows
  max_steps = 10, # hard safety cap on code executions
  dir = "~/Desktop/Code"
)

# 4. What you got back ----------------------------------------------------
res # leaderboards, tally summary, constraints, report, cost
res$tally # every attempt: KEEP / DISCARD, best-so-far
res$test_leaderboard # final ranking on the held-out rows (the one to trust)
res$models # fitted models: predict(res$models[[1]], newdata)
res$dir # run directory: report.md, code.R, tally.csv, plots
cat(res$code, sep = "\n\n") # the full script the agent wrote

# The session is still live - ask it anything:
res$session$tell("why did the winning model win?")

# 5. Autonomous variant ----------------------------------------------------
# No approval gate; generous exploration; hard budgets. Run it, walk away.
# res <- atlas(
#   data, outcome,
#   autonomous      = TRUE,
#   n_models        = 6,
#   stopping_rounds = 5,             # stop after 5 flat attempts in a row
#   max_steps       = 200,
#   max_runtime     = 1800,          # 30 minutes, mechanically enforced
#   test_prop       = 0.2,
#   exclude         = exclude,
#   dir             = "~/atlas-runs/first-auto"
# )
#
# ...and steer it mid-run from ANOTHER R session or terminal:
# atlas::atlas_message("~/atlas-runs/first-auto",
#                      "focus on gradient boosting; stop engineering ratios")

# 6. Come back later -------------------------------------------------------
# s <- atlas_resume(res$dir)
# s$tell("add one more candidate that uses at most 5 predictors")
