---
name: realtime-ros2-optimization
description: Practical rules for writing predictable, low-latency, and real-time safe ROS 2 code.
license: "See repository LICENSE"
user-invocable: false
---

# Real-Time ROS 2 Optimization

Use this skill when developing or reviewing ROS 2 C++ code for high-frequency control, deterministic sensor processing, low-jitter actuation, or safety-critical robotics.

Primary target: ROS 2 Humble on Ubuntu 22.04. When distro behavior differs, prefer Humble APIs, Humble docs, and Humble defaults over Rolling/Kilted-era advice.

## Priorities

Apply these in order:

1. **Determinism**: Consistent timing beats average throughput.
2. **Bounded Latency**: Keep callback runtimes short and predictable.
3. **Allocation-Free Hot Paths**: No steady-state heap churn in control or sensor loops.
4. **Explicit Concurrency**: Design callback groups and executors together.
5. **Data Freshness**: Prefer current data over stale but reliable backlogs.

## Core Rules

### 1. Execution & Determinism

- `rclcpp::spin(node)` is effectively a `SingleThreadedExecutor`. Do not expect parallelism unless you explicitly choose another executor.
- `MultiThreadedExecutor` is a thread pool, not a scheduling guarantee. Real parallelism depends on callback groups.
- In Humble, component containers also default to single-threaded execution unless you deliberately choose another execution model.
- `StaticSingleThreadedExecutor` reduces node-structure scanning overhead, but only use it when subscriptions, timers, services, and actions are created during initialization and stay stable afterward.
- Under overload, executor scheduling is not strict FIFO. Ready entities are surfaced through a wait set with coarse readiness flags, so do not encode control assumptions around callback arrival order.
- Timer prioritization that existed in older ROS 2 discussions was removed. Treat timers as peers in executor scheduling, not privileged work.
- For strict processing order or batch-style handling of multiple inputs, prefer `rclcpp::WaitSet` and manually `take()` messages in the order your control law requires.
- When specific callbacks must run at different priorities, split them into separate callback groups and, if needed, separate executors via `add_callback_group(...)`, then apply OS thread priorities outside ROS 2.

```cpp
// Humble-friendly pattern: isolate the control timer from sensor ingestion.
control_group_ = this->create_callback_group(rclcpp::CallbackGroupType::MutuallyExclusive);
sensor_group_ = this->create_callback_group(rclcpp::CallbackGroupType::MutuallyExclusive);

rclcpp::SubscriptionOptions sensor_options;
sensor_options.callback_group = sensor_group_;

imu_sub_ = this->create_subscription<sensor_msgs::msg::Imu>(
  "/imu",
  rclcpp::SensorDataQoS().keep_last(1),
  std::bind(&Node::imu_callback, this, std::placeholders::_1),
  sensor_options);

control_timer_ = this->create_wall_timer(
  1ms,
  std::bind(&Node::control_step, this),
  control_group_);
```

### 2. Callback Groups & Deadlock Prevention

- Treat callback groups as part of the node architecture, not as an afterthought.
- The default callback group is `MutuallyExclusive`. If you put every timer, subscription, and client there, the node behaves like it is single-threaded even under a `MultiThreadedExecutor`.
- Store callback groups as class members. If the group handle is not retained, the executor cannot dispatch callbacks associated with it.
- Use one `MutuallyExclusive` group for callbacks that share non-thread-safe state and must never overlap.
- Use different `MutuallyExclusive` groups when callbacks may run in parallel, but each callback must not overlap itself.
- Use `Reentrant` only when overlapping instances of the same callback are actually safe.
- Hidden callbacks matter. Service clients, action clients, and futures create done-callbacks that inherit the callback group of the entity that spawned them.
- The CTU MRS examples show a common trap: multiple timers do not run in parallel if they were all created in the same mutually exclusive group.

### 3. Blocking Calls, Futures, and Deadlocks

- Prefer asynchronous service and action calls in callbacks.
- In `rclcpp`, there is no synchronous service client API, but `async_send_request(...); future.wait_for(...)` inside a callback has the same deadlock risk as a synchronous call.
- A callback that blocks waiting for a service or action result must not share the same `MutuallyExclusive` group as the client or action entity that will deliver the completion callback.
- If a blocking wait inside a callback is unavoidable, place the waiting callback and the client/action in different callback groups, or use a `Reentrant` group only if re-entry is genuinely safe.
- Never block a high-rate control-loop timer waiting for a service/action response. Hand the request off asynchronously and advance state when the completion callback arrives.

```cpp
// Prefer completion callbacks over waiting inside the timer/subscription callback.
auto request = std::make_shared<Srv::Request>();
auto result_future = client_->async_send_request(request,
  [this](rclcpp::Client<Srv>::SharedFuture future) {
    auto response = future.get();
    (void)response;
    this->handle_service_result();
  });
```

### 4. Memory & Real-Time Safety

- Pre-allocate message buffers, vectors, and work queues during initialization. Use `reserve()` and fixed-capacity structures where practical.
- Avoid `new`, uncontrolled `std::vector::push_back`, string formatting, parameter lookup, and heavy logging in hot callbacks.
- Prefer moving data out of high-rate callbacks into preallocated ring buffers or single-producer/single-consumer queues.
- Use `std::atomic` or lock-free handoff for lightweight state exchange. If a mutex is unavoidable, keep it out of the tight control path.
- For hard real-time systems, use `mlockall(MCL_CURRENT | MCL_FUTURE)` and warm up code paths before enabling the controller to avoid first-use page faults.
- Use `rclcpp::LoanedMessage` and intra-process communication for large payloads only when the selected Humble RMW path actually supports it well enough for your system.

```cpp
// Prefer publisher-side loaned messages only after verifying RMW support on Humble.
auto loaned = pub_->borrow_loaned_message();
loaned.get().data = next_value_;
pub_->publish(std::move(loaned));
```

### 5. QoS, Backpressure, and Data Freshness

- Match QoS to the control objective, not to a generic reliability preference.
- High-rate sensors and control feedback usually want shallow queues and often `BestEffort` or `SensorDataQoS`, because stale data is often worse than dropped data.
- Be careful with deep reliable queues in controllers. They can preserve every sample while quietly destroying latency.
- ROS 2 keeps unread samples in the middleware rather than an extra client-library queue. That helps, but it also means overload behavior is strongly tied to middleware backpressure and executor responsiveness.
- Verify publisher/subscriber QoS compatibility explicitly. A mismatched reliable vs best-effort pairing can look like a performance bug when it is really a delivery contract mismatch.
- Use deadline, lifespan, and QoS event callbacks when the system has an actual timing contract that should fail loudly rather than degrade silently.

```cpp
// Good Humble default for high-rate sensor ingestion: shallow queue, latest data wins.
auto qos = rclcpp::SensorDataQoS().keep_last(1);

camera_sub_ = this->create_subscription<sensor_msgs::msg::Image>(
  "/camera/image_raw",
  qos,
  std::bind(&Node::image_callback, this, std::placeholders::_1));
```

### 6. Parameters, Sim Time, and ROS 2 Gotchas

- Declare parameters explicitly with `declare_parameter<T>()` before use.
- Loading an empty YAML file via launch can fail with a cryptic `'NoneType' object has no attribute 'items'` error. Keep at least one parameter in each YAML file.
- Access nested parameters with dot notation (`.`) in code.
- Use `this->get_clock()->now()` rather than wall-clock helpers in code that must respect `use_sim_time`.
- If a controller runs on simulated time, verify the `/clock` publication rate is high enough for the control frequency. A slow sim clock can destabilize an otherwise correct loop.

```cpp
// Declare once at startup; avoid undeclared-parameter surprises in Humble deployments.
control_rate_hz_ = this->declare_parameter<double>("control.rate_hz", 500.0);
use_feedforward_ = this->declare_parameter<bool>("control.use_feedforward", true);
```

### 7. Humble-Specific Notes

- Prefer Humble documentation URLs and examples when resolving API questions. Some newer guidance assumes post-Humble features or different defaults.
- In Humble, publisher-side loaned messages can use middleware-owned memory only on supported RMW implementations. The Humble docs list `rmw_fastrtps` as supported and `rmw_cyclonedds` / `rmw_connextdds` as unsupported for that path.
- In Humble, loaned-message subscriptions are disabled by default for safety reasons. Do not enable them in production unless you have verified the exact RMW behavior and failure modes.
- `use_sim_time` is per-node. In mixed systems, verify that every controller, estimator, and broadcaster that depends on simulation time has it enabled explicitly.
- If you are using `ros2_control` on Humble, treat `controller_manager` as part of the real-time surface. Its update loop supports `lock_memory`, `cpu_affinity`, and `thread_priority`, and it attempts to use `SCHED_FIFO` priority `50` when possible.
- For Humble hardware-control deployments, prefer a real-time or low-latency kernel over the stock throughput-optimized kernel.

```yaml
# Humble ros2_control example: pin the update loop and reduce page-fault risk.
controller_manager:
  ros__parameters:
    update_rate: 500
    lock_memory: true
    cpu_affinity: [2]
    thread_priority: 80
```

```bash
# Typical Humble/Linux setup for ros2_control real-time permissions.
sudo addgroup realtime
sudo usermod -a -G realtime "$USER"
```

## Review Heuristics

Look for:

- `MultiThreadedExecutor` used with no explicit callback groups.
- Callback groups created but not stored as members.
- Blocking waits on futures inside timers, subscriptions, or service callbacks.
- Assumptions that executor scheduling is FIFO or that timers are implicitly prioritized.
- `StaticSingleThreadedExecutor` used even though the node creates entities dynamically after startup.
- `std::mutex`, heap allocation, or unbounded container growth in control-loop callbacks.
- Mismatched QoS or deep queues on high-frequency topics.
- Missing `declare_parameter<T>()` for required parameters.
- Assumptions that loaned messages are zero-copy on all Humble RMWs.
- `ros2_control` deployments that omit `lock_memory`, CPU affinity, or thread-priority tuning even though jitter requirements are strict.

## Quick Checklist

- [ ] Executor choice matches the node's concurrency model.
- [ ] `MultiThreadedExecutor` is paired with deliberate callback-group design.
- [ ] Callback groups are stored and assigned explicitly.
- [ ] No blocking wait on futures inside hot callbacks.
- [ ] No heap churn or unbounded growth in steady-state control paths.
- [ ] QoS settings bound backlog and preserve data freshness.
- [ ] All YAML config files contain at least one valid parameter.
- [ ] Sim time paths use `this->get_clock()->now()` and a verified `/clock` rate.
- [ ] Humble-specific middleware assumptions are validated, especially for loaned messages.
- [ ] `ros2_control` update-loop scheduling settings are explicit when hardware jitter matters.

## Good References

- ROS 2 docs: executors, callback groups, and wait-set behavior
- ROS 2 docs: Humble QoS settings and loaned-message support caveats
- ros2_control Humble docs: controller_manager determinism, `lock_memory`, `cpu_affinity`, `thread_priority`
- CTU MRS `ros2_examples`: timer, service-client, QoS, and sim-time gotchas
- William Woodall's executor talk for the broader execution model and tradeoffs


