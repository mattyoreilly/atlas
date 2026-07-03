
# Explore the data
str(data)
summary(data)



# Check for missing values
cat("Missing values per column:\n")
colSums(is.na(data))

cat("\n\nOutcome (mpg) distribution:\n")
hist(data$mpg, main="Distribution of MPG", xlab="MPG", col="lightblue")



# Set up train/test split
set.seed(42)
n <- nrow(data)
train_idx <- sample(1:n, size = round(0.75 * n))
train_data <- data[train_idx, ]
test_data <- data[-train_idx, ]

cat("Training set:", nrow(train_data), "observations\n")
cat("Test set:", nrow(test_data), "observations\n")



# Model 1: Simple Linear Regression with stepwise selection
# Start with key predictors: wt, hp, cyl
model1_full <- lm(mpg ~ wt + hp + cyl, data = train_data)

# Try stepwise in both directions
model1 <- step(model1_full, scope = list(lower = ~ 1, upper = ~ wt + hp + cyl + disp + drat + qsec + vs + am + gear + carb),
               direction = "both", trace = 0)

cat("Model 1: Simple Linear Regression\n")
summary(model1)

# Predict on test set
pred1 <- predict(model1, newdata = test_data)
rmse1 <- sqrt(mean((test_data$mpg - pred1)^2))
cat("\n\nTest RMSE:", round(rmse1, 3), "\n")



# Model 2: Elastic Net Regression
# Check if glmnet is available
if (requireNamespace("glmnet", quietly = TRUE)) {
  library(glmnet)
  
  # Prepare matrices
  X_train <- as.matrix(train_data[, -1])  # Remove mpg
  y_train <- train_data$mpg
  X_test <- as.matrix(test_data[, -1])
  y_test <- test_data$mpg
  
  # Use cross-validation to find optimal lambda (alpha=0.5 for elastic net)
  set.seed(42)
  cv_model2 <- cv.glmnet(X_train, y_train, alpha = 0.5, nfolds = 5)
  
  # Fit final model with best lambda
  model2 <- glmnet(X_train, y_train, alpha = 0.5, lambda = cv_model2$lambda.min)
  
  cat("Model 2: Elastic Net Regression\n")
  cat("Optimal lambda:", round(cv_model2$lambda.min, 4), "\n\n")
  cat("Coefficients:\n")
  print(coef(model2))
  
  # Predict on test set
  pred2 <- predict(model2, newx = X_test, s = cv_model2$lambda.min)
  rmse2 <- sqrt(mean((y_test - pred2)^2))
  cat("\nTest RMSE:", round(rmse2, 3), "\n")
  
  glmnet_available <- TRUE
} else {
  cat("glmnet package not available, using ridge regression with MASS instead\n")
  glmnet_available <- FALSE
}



# Fallback: Use ridge regression with lm.ridge from MASS
if (requireNamespace("MASS", quietly = TRUE)) {
  library(MASS)
  
  # Standardize predictors for ridge regression
  train_scaled <- as.data.frame(scale(train_data[, -1]))
  train_scaled$mpg <- train_data$mpg
  
  # Find optimal lambda using GCV
  ridge_model <- lm.ridge(mpg ~ ., data = train_scaled, lambda = seq(0, 10, 0.1))
  optimal_lambda <- ridge_model$lambda[which.min(ridge_model$GCV)]
  
  # Fit with optimal lambda
  model2 <- lm.ridge(mpg ~ ., data = train_scaled, lambda = optimal_lambda)
  
  cat("Model 2: Ridge Regression\n")
  cat("Optimal lambda:", round(optimal_lambda, 4), "\n\n")
  cat("Coefficients:\n")
  print(coef(model2))
  
  # Predict on test set (need to scale test data using training means/sds)
  test_scaled <- sweep(test_data[, -1], 2, attr(scale(train_data[, -1]), "scaled:center"), "-")
  test_scaled <- sweep(test_scaled, 2, attr(scale(train_data[, -1]), "scaled:scale"), "/")
  
  # Manual prediction: intercept + beta * X
  pred2 <- as.matrix(cbind(1, test_scaled)) %*% coef(model2)
  rmse2 <- sqrt(mean((test_data$mpg - pred2)^2))
  cat("\nTest RMSE:", round(rmse2, 3), "\n")
  
  mass_available <- TRUE
} else {
  cat("MASS package not available either\n")
  mass_available <- FALSE
}



# Model 3: Polynomial model with quadratic terms for key predictors
# Add squared terms for wt and hp (most predictive based on domain knowledge)
model3 <- lm(mpg ~ wt + I(wt^2) + hp + I(hp^2) + cyl + am, data = train_data)

cat("Model 3: Polynomial Linear Model\n")
summary(model3)

# Predict on test set
pred3 <- predict(model3, newdata = test_data)
rmse3 <- sqrt(mean((test_data$mpg - pred3)^2))
cat("\n\nTest RMSE:", round(rmse3, 3), "\n")



# Refit all models on full dataset for final versions

# Model 1: Simple Linear Regression
final_model1 <- lm(mpg ~ wt + carb + gear, data = data)

# Model 2: Ridge Regression
data_scaled <- as.data.frame(scale(data[, -1]))
data_scaled$mpg <- data$mpg
final_model2 <- lm.ridge(mpg ~ ., data = data_scaled, lambda = optimal_lambda)

# Model 3: Polynomial Linear Model
final_model3 <- lm(mpg ~ wt + I(wt^2) + hp + I(hp^2) + cyl + am, data = data)

cat("All models refitted on full dataset (n=32)\n")



# Create atlas_models list
atlas_models <- list(
  simple_linear = final_model1,
  ridge_regression = final_model2,
  polynomial = final_model3
)

# Create atlas_leaderboard
atlas_leaderboard <- data.frame(
  name = c("polynomial", "ridge_regression", "simple_linear"),
  type = c("Polynomial Linear Model", "Ridge Regression", "Simple Linear Regression"),
  metric = rep("RMSE", 3),
  value = c(rmse3, rmse2, rmse1),
  notes = c(
    "Quadratic terms for wt & hp; captures non-linearity",
    "Ridge penalty (λ=10); all predictors with shrinkage",
    "3 predictors: wt, carb, gear; highly interpretable"
  ),
  stringsAsFactors = FALSE
)

# Sort by best performance (lowest RMSE)
atlas_leaderboard <- atlas_leaderboard[order(atlas_leaderboard$value), ]
rownames(atlas_leaderboard) <- NULL

cat("LEADERBOARD:\n")
print(atlas_leaderboard)



# Generate detailed summaries for the report
cat("=== FINAL MODEL SUMMARIES ===\n\n")

cat("MODEL 1: Simple Linear Regression\n")
cat("----------------------------------\n")
summary(final_model1)

cat("\n\nMODEL 2: Ridge Regression\n")
cat("----------------------------------\n")
cat("Lambda:", optimal_lambda, "\n")
cat("Coefficients:\n")
print(coef(final_model2))

cat("\n\nMODEL 3: Polynomial Linear Model\n")
cat("----------------------------------\n")
summary(final_model3)

