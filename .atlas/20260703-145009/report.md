Excellent! Now let me create the final markdown report:

---

# MPG Prediction Model Report

## Data Summary

The dataset contains **32 observations** of automobiles with **11 variables** (1 outcome + 10 predictors). The outcome variable `mpg` (miles per gallon) ranges from 10.4 to 33.9 with a mean of 20.1 mpg. **No missing values** were detected in any variable.

The predictors include:
- **Continuous variables**: displacement (disp), horsepower (hp), rear axle ratio (drat), weight (wt), quarter-mile time (qsec)
- **Discrete/categorical variables**: cylinders (cyl), engine shape (vs), transmission (am), gears (gear), carburetors (carb)

**Validation approach**: 75/25 train-test split (24 training, 8 test observations) with fixed seed (42) for reproducibility.

---

## Model 1: Simple Linear Regression

### Build Process
- **Feature selection**: Forward/backward stepwise selection starting from key predictors (wt, hp, cyl)
- **Final predictors**: Weight (wt), carburetors (carb), and gears (gear)
- **Preprocessing**: None - raw predictors used for maximum interpretability
- **Tuning**: Automated stepwise selection based on AIC

### Performance
- **Test RMSE**: 4.178
- **Training R²**: 0.817 (Adjusted: 0.798)
- **Interpretation**: 
  - Each 1000 lb increase in weight decreases mpg by 3.31 (p < 0.01)
  - Each additional carburetor decreases mpg by 1.48 (p < 0.01)
  - Each additional gear increases mpg by 2.25 (p = 0.06)

### Strengths
- **Highly interpretable** - only 3 predictors with clear coefficient meanings
- **Good fit** - explains 81.7% of variance
- **Statistically significant** overall model (p < 0.001)

---

## Model 2: Ridge Regression

### Build Process
- **Method**: Ridge regression (L2 penalty) using all 10 predictors
- **Preprocessing**: All predictors standardized (mean=0, sd=1)
- **Tuning**: Lambda selected via generalized cross-validation (GCV)
- **Optimal lambda**: 10.0

### Performance
- **Test RMSE**: 3.711
- **Key coefficients** (on standardized scale):
  - Weight (wt): -1.33
  - Horsepower (hp): -0.82
  - Carburetors (carb): -0.96
  - Transmission (am): +0.87
  - Displacement (disp): -0.60

### Strengths
- **Handles multicollinearity** - many predictors are correlated (e.g., cyl, disp, hp)
- **Uses all information** - incorporates all 10 predictors with appropriate shrinkage
- **Better generalization** - 11% improvement over simple linear model
- **Still interpretable** - coefficients show relative importance on standardized scale

---

## Model 3: Polynomial Linear Model

### Build Process
- **Features**: Linear and quadratic terms for weight (wt, wt²) and horsepower (hp, hp²), plus cylinders (cyl) and transmission (am)
- **Rationale**: Captures non-linear relationships while maintaining interpretability within the linear model framework
- **Preprocessing**: None - polynomial terms created from raw predictors
- **Tuning**: Manual feature engineering based on domain knowledge

### Performance
- **Test RMSE**: 3.488 ⭐ **BEST**
- **Training R²**: 0.891 (Adjusted: 0.865)
- **Key findings**:
  - Weight has a **curved relationship** with mpg (negative linear + positive quadratic)
  - Horsepower shows **diminishing negative effect** (quadratic term p = 0.07)
  - Model explains 89.1% of variance

### Strengths
- **Best predictive performance** - lowest test error
- **Captures non-linearity** - quadratic terms model realistic diminishing returns
- **Interpretable within linear framework** - can explain the curved relationships
- **Statistically strong** - highly significant overall model (p < 0.001)

---

## Recommendation

**Choose Model 3 (Polynomial Linear Model)** for the following reasons:

1. **Best Performance**: Achieves the lowest test RMSE (3.488), representing a 17% improvement over the simple linear model

2. **Realistic Modeling**: The quadratic terms capture the non-linear reality that incremental increases in weight or horsepower have non-constant effects on fuel efficiency

3. **Maintains Interpretability**: While more complex than Model 1, the polynomial model remains within the linear regression framework and coefficients can be meaningfully interpreted (e.g., "the negative effect of weight on mpg diminishes at higher weights")

4. **Balanced Complexity**: Uses only 6 predictors with 2 polynomial terms - not overfit despite small sample size (R² = 0.89 with adjusted R² = 0.86 shows minimal shrinkage)

**Alternative**: If maximum simplicity is required, Model 1 (Simple Linear) provides a reasonable approximation with just 3 easily interpretable coefficients, though at the cost of ~15% higher prediction error.

---

## Objects Created

- `atlas_models`: Named list containing all three final models fitted on full data
- `atlas_leaderboard`: Data frame with model comparison metrics sorted by performance
