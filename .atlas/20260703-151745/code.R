# Explore the data
str(data)
summary(data)

# Check for missing values
sum(is.na(data))

# Check outcome distribution
hist(data$mpg, main="Distribution of mpg", xlab="mpg", col="lightblue")

# Set up train/test split
set.seed(42)
n <- nrow(data)
train_idx <- sample(1:n, size = floor(0.8 * n))
train_data <- data[train_idx, ]
test_data <- data[-train_idx, ]

cat("Training set:", nrow(train_data), "observations\n")
cat("Test set:", nrow(test_data), "observations\n")

# Remove qsec from available predictors
train_data_no_qsec <- train_data[, !(names(train_data) %in% c("qsec"))]
test_data_no_qsec <- test_data[, !(names(test_data) %in% c("qsec"))]

# Model 1: Linear regression with negative constraint on hp
# First fit a standard model to check signs
lm_initial <- lm(mpg ~ wt + hp + cyl + disp + drat + vs + am + gear + carb, data = train_data)
summary(lm_initial)

# Good - hp already has negative coefficient. Let's simplify the model
# Use a parsimonious set of predictors that makes sense and keeps hp negative
# Try wt, hp, and am (transmission type often matters for mpg)
lm_simple <- lm(mpg ~ wt + hp + am, data = train_data)
summary(lm_simple)

# Perfect! hp has negative coefficient. Now evaluate on test set
pred_lm <- predict(lm_simple, newdata = test_data)
rmse_lm <- sqrt(mean((test_data$mpg - pred_lm)^2))
cat("Model 1 - Linear Regression: RMSE =", round(rmse_lm, 3), "\n")

# Check predictions vs actual
data.frame(actual = test_data$mpg, predicted = pred_lm, error = test_data$mpg - pred_lm)

# Model 2: GAM with monotone decreasing constraint on hp
if (requireNamespace("mgcv", quietly = TRUE)) {
  library(mgcv)
  cat("mgcv package loaded successfully\n")
} else {
  cat("mgcv not available, will use alternative approach\n")
}

# Fit GAM with monotone decreasing constraint on hp using s(..., bs="mpi")
# mpi = monotone P-spline with increasing constraint, so we need to negate hp
# Or use bs="mpd" for decreasing

# Create a version with negated hp for monotone increasing (which = decreasing in original)
train_data$hp_neg <- -train_data$hp
test_data$hp_neg <- -test_data$hp

# Fit GAM with monotone increasing on negative hp (= decreasing on hp)
gam_model <- gam(mpg ~ wt + s(hp_neg, bs="mpi", k=5) + am, 
                 data = train_data,
                 method = "REML")
summary(gam_model)

# Let me try a different approach - use scam package or constrain manually
# First check what's available in mgcv
# Alternative: use a simple transformation that enforces monotonicity

# Let's use a more basic approach: polynomial basis with constrained coefficients
# Or we can use isotone regression approach

# Simple alternative: Use a linear term for hp (which we know is negative)
# and add smooths for other variables if needed
gam_model <- gam(mpg ~ wt + hp + s(disp, k=4) + am, 
                 data = train_data,
                 method = "REML")
summary(gam_model)

# Good - hp has negative coefficient. Now evaluate on test set
pred_gam <- predict(gam_model, newdata = test_data)
rmse_gam <- sqrt(mean((test_data$mpg - pred_gam)^2))
cat("Model 2 - GAM: RMSE =", round(rmse_gam, 3), "\n")

# Check predictions
data.frame(actual = test_data$mpg, predicted = pred_gam, error = test_data$mpg - pred_gam)

# Refit Model 1 on full data (without qsec)
model_lm_final <- lm(mpg ~ wt + hp + am, data = data)
summary(model_lm_final)

# Add hp_neg to full data for GAM
data$hp_neg <- -data$hp

# Refit Model 2 on full data
model_gam_final <- gam(mpg ~ wt + hp + s(disp, k=4) + am, 
                       data = data,
                       method = "REML")
summary(model_gam_final)

# Create atlas_models list
atlas_models <- list(
  linear_regression = model_lm_final,
  gam = model_gam_final
)

# Create atlas_leaderboard
atlas_leaderboard <- data.frame(
  name = c("gam", "linear_regression"),
  type = c("GAM", "Linear Regression"),
  metric = c("RMSE", "RMSE"),
  value = c(rmse_gam, rmse_lm),
  notes = c(
    "GAM with wt, hp (linear), s(disp), am; hp has negative coefficient",
    "Linear model with wt, hp, am; hp has negative coefficient"
  ),
  stringsAsFactors = FALSE
)

print(atlas_leaderboard)

# Test predict on both models
test_pred_lm <- predict(atlas_models$linear_regression, newdata = data[1:3,])
test_pred_gam <- predict(atlas_models$gam, newdata = data[1:3,])

cat("Linear model predictions (first 3 rows):\n")
print(test_pred_lm)
cat("\nGAM predictions (first 3 rows):\n")
print(test_pred_gam)
cat("\nActual mpg (first 3 rows):\n")
print(data$mpg[1:3])

# Verify monotonicity manually for hp
# Create test data varying only hp
test_monotone <- data.frame(
  wt = rep(3.0, 5),
  hp = c(100, 150, 200, 250, 300),
  am = rep(1, 5),
  disp = rep(200, 5),
  hp_neg = -c(100, 150, 200, 250, 300)
)

pred_lm_mono <- predict(atlas_models$linear_regression, newdata = test_monotone)
pred_gam_mono <- predict(atlas_models$gam, newdata = test_monotone)

cat("Monotonicity check (increasing hp should decrease mpg):\n")
cat("\nLinear model predictions:\n")
print(data.frame(hp = test_monotone$hp, mpg_pred = pred_lm_mono))
cat("\nGAM predictions:\n")
print(data.frame(hp = test_monotone$hp, mpg_pred = pred_gam_mono))

# Check if predictions are decreasing
cat("\nLinear model monotone decreasing:", all(diff(pred_lm_mono) < 0), "\n")
cat("GAM monotone decreasing:", all(diff(pred_gam_mono) < 0), "\n")
