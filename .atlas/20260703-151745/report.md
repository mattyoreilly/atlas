I'll build 2 models to predict `mpg` from the other columns, keeping in mind the hard constraints. Let me start by exploring the data.
**Data Exploration Summary:**
The dataset has 32 observations with 11 variables and no missing values. The outcome `mpg` ranges from 10.4 to 33.9 with a mean of 20.09, showing a fairly continuous distribution suitable for regression.

Now let me propose my modeling plan:
Great! Let me proceed with the modeling.
**Model 1 - Linear Regression: RMSE = 3.178**

Now let me build the second model using GAM with monotone constraint:
**Model 2 - GAM: RMSE = 2.583**

Now let me refit both models on the full dataset and create the required outputs:
Now let me verify the constraints are satisfied:
Perfect! All constraints are satisfied. Let me verify the models work correctly with predict:
Excellent! Both models satisfy all constraints. Now let me create the final report:

---

# MPG Prediction Model Report

## Data Summary

The dataset contains 32 observations of automobiles with 11 variables. The target variable `mpg` (miles per gallon) ranges from 10.4 to 33.9 with a mean of 20.09. There are no missing values. Key predictors include weight (`wt`), horsepower (`hp`), displacement (`disp`), and transmission type (`am`).

## Validation Approach

- **Task Type**: Regression
- **Validation Method**: 80/20 holdout split (25 training, 7 test observations)
- **Random Seed**: 42
- **Evaluation Metric**: Root Mean Squared Error (RMSE) on held-out test set
- **Constraints Enforced**:
  - `wt` used as predictor in both models ✓
  - Predictions monotonically decreasing in `hp` ✓
  - `qsec` excluded from all models ✓

---

## Model 1: Linear Regression

### Construction
A parsimonious linear regression model using three predictors:
- **wt** (weight): Required predictor, negative relationship with mpg
- **hp** (horsepower): Linear term with negative coefficient (ensures monotone decreasing)
- **am** (transmission): Binary indicator for manual vs automatic

The model formula is: `mpg ~ wt + hp + am`

### Preprocessing & Features
- Excluded `qsec` (measured after the fact)
- Used raw predictor values without transformation
- No additional feature engineering

### Tuning
No hyperparameter tuning required for linear regression.

### Validation Performance
- **Test RMSE**: 3.178
- All coefficients have expected signs (wt and hp negative)
- R² = 0.84 on full data
- hp coefficient = -0.037 (p < 0.001), ensuring monotone decreasing predictions

---

## Model 2: Generalized Additive Model (GAM)

### Construction
A GAM combining linear and smooth terms:
- **wt** (weight): Linear term, required predictor
- **hp** (horsepower): Linear term with negative coefficient (ensures monotone decreasing)
- **disp** (displacement): Smooth term s(disp, k=4) to capture non-linearity
- **am** (transmission): Linear term

The model formula is: `mpg ~ wt + hp + s(disp, k=4) + am`

### Preprocessing & Features
- Excluded `qsec` (measured after the fact)
- Used penalized regression splines via `mgcv::gam`
- REML smoothness selection for optimal bias-variance tradeoff

### Tuning
- Smooth term basis dimension k=4 for displacement
- Smoothing parameters optimized via REML

### Validation Performance
- **Test RMSE**: 2.583 (18.7% better than linear model)
- hp coefficient = -0.027 (p < 0.05), ensuring monotone decreasing predictions
- Smooth term for disp significant (p = 0.023 on full data)
- R² (adjusted) = 0.87 on full data

---

## Recommendation

**I recommend the GAM model** for the following reasons:

1. **Better Predictive Performance**: Test RMSE of 2.583 vs 3.178 for linear regression (18.7% improvement)

2. **Flexibility**: Captures non-linear relationships (especially with displacement) while maintaining constraints

3. **Constraint Satisfaction**: Both models satisfy all hard constraints, but GAM achieves this with better accuracy

4. **Model Fit**: Higher adjusted R² (0.87 vs 0.82) with similar model complexity

5. **Robustness**: The smooth term for displacement is statistically significant, suggesting real non-linear patterns in the data

The GAM provides superior out-of-sample performance while respecting all modeling constraints, making it the preferred choice for predicting mpg.

