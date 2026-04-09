---
name: ekf-state-estimation
description: Practical rules for designing, implementing, and reviewing Extended Kalman Filter pipelines for real-time state estimation.
license: "See repository LICENSE"
user-invocable: false
---

# EKF State Estimation

Use this skill when building or reviewing Extended Kalman Filter (EKF) systems for robotics or embedded estimation, especially when combining IMU and exteroceptive sensors under real-time constraints where numerical stability, observability, and bounded latency matter.

Canonical EKF model used by this skill:

- State estimate `x_hat in R^n`, covariance `P in R^(n x n)` (symmetric positive-definite).
- Process model: `x_k = f(x_(k-1), u_k) + w_k`, with `w_k ~ N(0, Q)`.
- Observation model: `z_k = h(x_k) + v_k`, with `v_k ~ N(0, R)`.
- Jacobians: `F = df/dx`, `H = dh/dx`, evaluated at the current linearization point.
- Predict: `x_hat_k^- = f(x_hat_(k-1), u_k)`, `P_k^- = F P_(k-1) F^T + Q`.
- Update: `y_tilde = z_k - h(x_hat_k^-)`, `S = H P_k^- H^T + R`, `K = P_k^- H^T S^-1`, `x_hat_k = x_hat_k^- + K y_tilde`.

## Priorities

Apply these in order:

1. **Numerical Stability**: Prevent divergence through stable covariance and gain computations.
2. **Correct Jacobians**: Keep linearization faithful to the true nonlinear model.
3. **Positive-Definite Covariance**: Maintain symmetric positive-definite covariance at every step.
4. **Observability Awareness**: Do not estimate what the sensor suite cannot observe.
5. **Sensor-Noise Tuning**: Tune Q and R from measured statistics, not guesses.
6. **Bounded Latency**: Keep predict/update work deterministic and real-time safe.
7. **Testability**: Validate with simulation, finite differences, and reproducible regression tests.

## Core Rules

### 1. Separate Predict and Update

- Keep propagation and correction in separate methods to avoid hidden side effects.
- Use `predict()` for process model and covariance propagation only.
- Use `update()` for innovation, gating, Kalman gain, and posterior update only.
- Keep `f(x, u)` and `h(x)` pure and testable so unit tests can verify each model independently.
- Log pre/post state and covariance norms per phase to isolate instability quickly.

```cpp
#include <Eigen/Dense>

struct Ekf {
  Eigen::VectorXd x;  // state estimate
  Eigen::MatrixXd P;  // covariance

  void predict(const Eigen::VectorXd& u,
               const Eigen::MatrixXd& Q,
               const Eigen::MatrixXd& F) {
    x = f(x, u);
    P = F * P * F.transpose() + Q;
  }

  void update(const Eigen::VectorXd& z,
              const Eigen::MatrixXd& R,
              const Eigen::MatrixXd& H) {
    const Eigen::VectorXd y = z - h(x);
    const Eigen::MatrixXd S = H * P * H.transpose() + R;
    const Eigen::MatrixXd K = P * H.transpose() * S.ldlt().solve(Eigen::MatrixXd::Identity(S.rows(), S.cols()));
    x = x + K * y;
    const Eigen::MatrixXd I = Eigen::MatrixXd::Identity(x.size(), x.size());
    P = (I - K * H) * P;
  }

  static Eigen::VectorXd f(const Eigen::VectorXd& x, const Eigen::VectorXd& u) {
    return x + u;
  }

  static Eigen::VectorXd h(const Eigen::VectorXd& x) {
    return x.head(2);
  }
};
```

### 2. Always Compute Jacobians Analytically and Verify with Finite Differences

- Derive F and H from first-order Taylor linearization around the current estimate.
- Prefer analytic closed forms in production for speed and deterministic runtime.
- Validate each Jacobian entry using central finite differences during tests.
- Use a fixed perturbation epsilon and compare absolute plus relative error.
- Fail CI if Jacobian mismatch exceeds tolerance in representative operating points.

```cpp
#include <Eigen/Dense>
#include <cmath>
#include <iostream>

Eigen::VectorXd h(const Eigen::VectorXd& x) {
  Eigen::VectorXd z(2);
  const double px = x(0);
  const double py = x(1);
  z(0) = std::sqrt(px * px + py * py);
  z(1) = std::atan2(py, px);
  return z;
}

Eigen::MatrixXd H_analytic(const Eigen::VectorXd& x) {
  Eigen::MatrixXd H = Eigen::MatrixXd::Zero(2, x.size());
  const double px = x(0);
  const double py = x(1);
  const double r2 = px * px + py * py;
  const double r = std::sqrt(r2);
  H(0, 0) = px / r;
  H(0, 1) = py / r;
  H(1, 0) = -py / r2;
  H(1, 1) = px / r2;
  return H;
}

Eigen::MatrixXd H_finite_difference(const Eigen::VectorXd& x, double eps) {
  const int n = x.size();
  const int m = h(x).size();
  Eigen::MatrixXd H = Eigen::MatrixXd::Zero(m, n);
  for (int i = 0; i < n; ++i) {
    Eigen::VectorXd xp = x;
    Eigen::VectorXd xm = x;
    xp(i) += eps;
    xm(i) -= eps;
    H.col(i) = (h(xp) - h(xm)) / (2.0 * eps);
  }
  return H;
}

int main() {
  Eigen::VectorXd x(4);
  x << 2.0, 1.0, 0.3, -0.2;
  const Eigen::MatrixXd Ha = H_analytic(x);
  const Eigen::MatrixXd Hn = H_finite_difference(x, 1e-6);
  std::cout << "max abs Jacobian error: " << (Ha - Hn).cwiseAbs().maxCoeff() << "\n";
  return 0;
}
```

### 3. Use Joseph-Form Covariance Update for Numerical Stability

- Standard covariance update can lose symmetry and positive-definiteness under finite precision.
- Use Joseph form: `(I-KH)P(I-KH)^T + K R K^T` in production EKF loops.
- Re-symmetrize covariance after update with `0.5*(P+P^T)`.
- Use decomposition-based solves (`LDLT` or `LLT`) instead of explicit matrix inverse.
- Validate that posterior covariance eigenvalues stay non-negative after each update.

```cpp
#include <Eigen/Dense>

void joseph_update(Eigen::VectorXd& x,
                   Eigen::MatrixXd& P,
                   const Eigen::VectorXd& y,
                   const Eigen::MatrixXd& H,
                   const Eigen::MatrixXd& R) {
  const Eigen::MatrixXd S = H * P * H.transpose() + R;
  const Eigen::MatrixXd Sinv = S.ldlt().solve(Eigen::MatrixXd::Identity(S.rows(), S.cols()));
  const Eigen::MatrixXd K = P * H.transpose() * Sinv;

  x = x + K * y;

  const Eigen::MatrixXd I = Eigen::MatrixXd::Identity(P.rows(), P.cols());
  const Eigen::MatrixXd A = I - K * H;
  P = A * P * A.transpose() + K * R * K.transpose();
  P = 0.5 * (P + P.transpose());
}
```

### 4. Use RK4 for Continuous-Time Process Model Integration

- For high-rate IMU propagation, Euler integration accumulates large linearization error.
- Integrate continuous-time dynamics with RK4 before covariance propagation.
- Keep integration timestep fixed and bounded in real-time loops.
- Compute F from discretized dynamics consistent with propagation scheme.
- Use RK4 especially when angular rates and accelerations change rapidly.

```cpp
#include <Eigen/Dense>

// Example state [p, v] in 1D with control acceleration a.
Eigen::VectorXd dynamics(const Eigen::VectorXd& x, double a) {
  Eigen::VectorXd dx(2);
  dx(0) = x(1);
  dx(1) = a;
  return dx;
}

Eigen::VectorXd rk4_step(const Eigen::VectorXd& x, double a, double dt) {
  const Eigen::VectorXd k1 = dynamics(x, a);
  const Eigen::VectorXd k2 = dynamics(x + 0.5 * dt * k1, a);
  const Eigen::VectorXd k3 = dynamics(x + 0.5 * dt * k2, a);
  const Eigen::VectorXd k4 = dynamics(x + dt * k3, a);
  return x + (dt / 6.0) * (k1 + 2.0 * k2 + 2.0 * k3 + k4);
}
```

### 5. Enforce Positive-Definiteness Actively

- Symmetrize covariance every cycle to cancel floating-point asymmetry.
- Detect near-singular covariance before solving for gain.
- Clamp tiny or negative eigenvalues to a minimum floor when needed.
- Prefer Cholesky (`LLT`) checks as a fast positive-definite health test.
- Treat repeated SPD repairs as a symptom of model mismatch or poor noise tuning.

```cpp
#include <Eigen/Dense>

bool enforce_spd(Eigen::MatrixXd& P, double min_eig = 1e-9) {
  P = 0.5 * (P + P.transpose());

  Eigen::SelfAdjointEigenSolver<Eigen::MatrixXd> es(P);
  if (es.info() != Eigen::Success) {
    return false;
  }

  Eigen::VectorXd d = es.eigenvalues();
  for (int i = 0; i < d.size(); ++i) {
    if (d(i) < min_eig) d(i) = min_eig;
  }
  P = es.eigenvectors() * d.asDiagonal() * es.eigenvectors().transpose();

  Eigen::LLT<Eigen::MatrixXd> llt(P);
  return llt.info() == Eigen::Success;
}
```

### 6. Apply Chi-Squared Innovation Gating Before Every Update

- Compute innovation Mahalanobis distance: `d2 = y^T S^{-1} y`.
- Reject outliers before state correction to prevent catastrophic jumps.
- Use chi-squared threshold from measurement dimension and confidence level.
- Track reject ratio per sensor stream; high reject rates usually indicate bad calibration or wrong R.
- Keep gating deterministic and cheap to preserve loop timing.

```cpp
#include <Eigen/Dense>

bool pass_gate(const Eigen::VectorXd& y,
               const Eigen::MatrixXd& S,
               double chi2_threshold) {
  const Eigen::VectorXd solved = S.ldlt().solve(y);
  const double d2 = y.transpose() * solved;
  return d2 < chi2_threshold;
}

// Example: 2D measurement at 95% confidence -> 5.991
void maybe_update(const Eigen::VectorXd& y, const Eigen::MatrixXd& S) {
  constexpr double kChi2_2d_95 = 5.991;
  if (!pass_gate(y, S, kChi2_2d_95)) {
    return;
  }
  // proceed with EKF correction
}
```

### 7. Perform Observability Analysis for the Actual Sensor Suite

- Explicitly identify unobservable modes (for example global yaw without absolute heading).
- Do not initialize or over-constrain states that are not observable from available sensors.
- Use linearized observability matrix rank checks during design and regression tests.
- State ordering should support efficient marginalization and consistent Jacobian blocks.
- In VIO pipelines, keep IMU core state first (position, velocity, orientation, biases) for stable block operations.

```cpp
#include <Eigen/Dense>
#include <iostream>

Eigen::MatrixXd observability_matrix(const Eigen::MatrixXd& F,
                                     const Eigen::MatrixXd& H,
                                     int steps) {
  const int n = F.rows();
  const int m = H.rows();
  Eigen::MatrixXd O = Eigen::MatrixXd::Zero(m * steps, n);

  Eigen::MatrixXd Fk = Eigen::MatrixXd::Identity(n, n);
  for (int k = 0; k < steps; ++k) {
    O.block(k * m, 0, m, n) = H * Fk;
    Fk = F * Fk;
  }
  return O;
}

int main() {
  Eigen::MatrixXd F(2, 2);
  F << 1.0, 1.0,
       0.0, 1.0;
  Eigen::MatrixXd H(1, 2);
  H << 1.0, 0.0;

  Eigen::MatrixXd O = observability_matrix(F, H, 4);
  Eigen::FullPivLU<Eigen::MatrixXd> lu(O);
  std::cout << "observability rank: " << lu.rank() << " / " << F.rows() << "\n";
  return 0;
}
```

### 8. Respect Lie-Group Structure for Orientation and Pose States

- Do not run plain Euclidean EKF directly on rotation matrices or unit quaternions.
- Represent nominal orientation on SO(3) and estimate small error in tangent space.
- Use left-invariant or right-invariant perturbation model consistently across predict and update.
- Re-normalize quaternion nominal state after propagation and correction.
- Never initialize global yaw from a single frame without absolute heading information.

```cpp
#include <Eigen/Dense>
#include <Eigen/Geometry>

Eigen::Quaterniond delta_quat_from_small_angle(const Eigen::Vector3d& dtheta) {
  const double angle = dtheta.norm();
  if (angle < 1e-12) {
    return Eigen::Quaterniond::Identity();
  }
  const Eigen::Vector3d axis = dtheta / angle;
  return Eigen::Quaterniond(Eigen::AngleAxisd(angle, axis));
}

void apply_left_perturbation(Eigen::Quaterniond& q_nominal,
                             const Eigen::Vector3d& dtheta) {
  const Eigen::Quaterniond dq = delta_quat_from_small_angle(dtheta);
  q_nominal = (dq * q_nominal).normalized();
}
```

### 9. Use CasADi for Jacobian Prototyping and Generate C for Deployment

- Prototype `f` and `h` symbolically with CasADi to avoid manual Jacobian mistakes.
- Use `jacobian(expr, x)` to generate exact analytic Jacobians for test comparison.
- Keep Python CasADi tooling out of hard real-time loops.
- Generate C code from CasADi functions, compile it, and call from C++ runtime.
- Cross-check generated Jacobians against hand-derived versions before release.

```python
import casadi as ca

# State x = [px, py, vx, vy], control u = [ax, ay], dt scalar
x = ca.SX.sym("x", 4)
u = ca.SX.sym("u", 2)
dt = ca.SX.sym("dt", 1)

f = ca.vertcat(
    x[0] + dt * x[2],
    x[1] + dt * x[3],
    x[2] + dt * u[0],
    x[3] + dt * u[1],
)
h = ca.vertcat(
    ca.sqrt(x[0] * x[0] + x[1] * x[1]),
    ca.atan2(x[1], x[0]),
)

F = ca.jacobian(f, x)
H = ca.jacobian(h, x)

f_fun = ca.Function("f_fun", [x, u, dt], [f, F])
h_fun = ca.Function("h_fun", [x], [h, H])

# Generate C sources for real-time integration into C++ build.
f_fun.generate("ekf_f_fun.c")
h_fun.generate("ekf_h_fun.c")
```

## Review Heuristics

Look for:
- Predict and update logic mixed in one function with hidden ordering bugs.
- Explicit matrix inverse (`.inverse()`) in gain or innovation computation.
- Covariance update not using Joseph form in noisy or long-running systems.
- Covariance matrix not symmetrized after update.
- No positive-definite checks before decomposition/solve.
- Jacobian code copied manually with no finite-difference validation test.
- Euler propagation used at high IMU rates where RK4 is required.
- Missing innovation gating or gating done after applying correction.
- Wrong chi-squared threshold dimension for the measurement vector.
- Yaw initialized from single-frame geometry without absolute heading input.
- Marginalization implemented by dropping rows/columns instead of Schur complement.
- New features/sensors inserted into state before delayed initialization is well-conditioned.

## Anti-Patterns

Avoid:
- Treating rotations as unconstrained 3D vectors in a Euclidean EKF state.
- Using unstable covariance update `(I-KH)P` only in numerically sensitive pipelines.
- Recomputing dynamic memory in every predict/update cycle.
- Guessing Q and R without sensor noise characterization.
- Ignoring repeated outlier rejections instead of debugging calibration/timestamps.
- Mixing units (degrees/radians, g/m/s^2) across process and measurement models.
- Updating with stale or out-of-order measurements without timestamp handling.
- Initializing full covariance as near-zero because it “looks confident”.
- Blindly trusting auto-diff Jacobians without runtime validation cases.
- Removing old states by truncating covariance instead of proper Schur marginalization.

## Quick Checklist

- [ ] State vector and covariance dimensions are documented and unit-consistent.
- [ ] `predict()` and `update()` are separate and independently testable.
- [ ] Process model `f(x,u)` and measurement model `h(x)` are pure functions.
- [ ] Jacobians F and H are analytic and covered by finite-difference regression tests.
- [ ] Gain and innovation solves use `LDLT`/`LLT`, not direct inverse.
- [ ] Joseph-form covariance update is used.
- [ ] Covariance is re-symmetrized every update.
- [ ] SPD health checks exist (Cholesky or eigenvalue floor).
- [ ] Propagation uses RK4 (or equivalent high-order integrator) at high sensor rates.
- [ ] Innovation chi-squared gate runs before every correction.
- [ ] Chi-squared thresholds match measurement dimension and confidence level.
- [ ] Observability assumptions are documented and tested (including yaw limitations).
- [ ] Orientation/pose error is defined on Lie algebra with invariant perturbation choice.
- [ ] Delayed initialization is used for weakly constrained new states/features.
- [ ] Marginalization path uses Schur complement and has numerical regression tests.

## Good References

- Wikipedia: Extended Kalman filter, https://en.wikipedia.org/wiki/Extended_Kalman_filter
- Simon D. Levy EKF tutorial, https://simondlevy.github.io/ekf-tutorial/
- OpenVINS repository (including `ov_msckf` implementation patterns), https://github.com/rpng/open_vins
- CasADi documentation and API, https://web.casadi.org/
- Joan Sola, A micro Lie theory for state estimation in robotics, https://arxiv.org/abs/1812.01537
- Forster et al., IMU Preintegration on Manifold for Efficient Visual-Inertial Maximum-a-Posteriori Estimation, https://arxiv.org/abs/1512.02363