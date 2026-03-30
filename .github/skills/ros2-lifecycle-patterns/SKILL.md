---
name: ros2-lifecycle-patterns
description: Practical guidance for designing, implementing, and reviewing ROS 2 managed nodes, lifecycle transitions, activation boundaries, and operational state handling on Humble.
license: "See repository LICENSE"
user-invocable: false
---

# ROS 2 Lifecycle Patterns

Use this skill when designing or reviewing managed nodes that use lifecycle state transitions. This is the narrower skill for activation/deactivation boundaries, startup sequencing, and stateful operational contracts.

Primary target: ROS 2 Humble on Ubuntu 22.04 unless the user says otherwise.

Use other ROS skills when the task is narrower:

- Use `ros2-best-practices` for general package, parameter, QoS, and launch guidance.
- Use `ros2-cpp-patterns` or `ros2-python-patterns` for language-specific implementation structure.
- Use `ros2-control-best-practices` when lifecycle-managed controllers or hardware components are part of the design.

## Priorities

Apply these in order:

1. **Clear State Semantics**: Every lifecycle transition should have a real operational meaning.
2. **Safe Activation Boundaries**: Do not publish, command hardware, or accept work before activation is complete.
3. **Deterministic Cleanup**: Deactivation and cleanup should leave the node in a known state.
4. **Operational Observability**: Startup failures and transition failures must be visible and actionable.
5. **Avoid Unneeded Complexity**: Use lifecycle only when managed state transitions solve a real deployment problem.

## Core Rules

### 1. Use Lifecycle Only for Real Operational States

- Do not introduce lifecycle nodes just because the API exists.
- Use managed nodes when startup ordering, activation/deactivation, hardware bring-up, or supervision genuinely matters.
- If a node has no meaningful distinction between configured, active, and inactive behavior, a normal node is often simpler.

### 2. Give Each Transition a Concrete Responsibility

- `on_configure`: allocate resources, declare parameters, create publishers/subscriptions/timers in a stopped or inactive state.
- `on_activate`: begin publishing or accepting live work.
- `on_deactivate`: stop live outputs and command emission.
- `on_cleanup`: release resources that should not survive a reset.
- `on_shutdown`: leave the process and external systems in a safe final state.
- Avoid mixing heavy runtime work across multiple transitions without a clear contract.

```cpp
rclcpp_lifecycle::node_interfaces::LifecycleNodeInterface::CallbackReturn
on_activate(const rclcpp_lifecycle::State &)
{
    publisher_->on_activate();
    active_ = true;
    return CallbackReturn::SUCCESS;
}
```

### 3. Do Not Leak Active Behavior into Inactive States

- Inactive nodes should not publish command outputs as if they were active.
- Timers or callbacks that remain created across transitions should check whether work is currently allowed.
- Avoid subscribers or service handlers that keep mutating live outputs after deactivation unless that is explicitly intended.
- Make the active/inactive boundary obvious in code.

### 4. Fail Fast on Broken Transitions

- If configuration or activation prerequisites are missing, fail the transition explicitly.
- Log why the transition failed in operational terms.
- Do not partially activate the node and hope later callbacks fill in missing state.
- Keep rollback behavior predictable when a later transition step fails.

### 5. Keep Transition Code Focused

- Transition callbacks should manage state boundaries, not embed full application logic.
- Extract validation, hardware setup, or configuration helpers when transition code grows too large.
- Keep side effects ordered and easy to audit.
- Do not hide important transition behavior in unrelated helper layers.

### 6. Coordinate Launch and Supervision Deliberately

- Lifecycle nodes often require explicit startup orchestration.
- If launch or supervision tooling triggers transitions, make that flow visible in launch files or orchestration code.
- Verify that dependent nodes do not assume activation before it actually occurs.
- For systems with several managed nodes, document the intended order of configure and activate steps.

### 7. Treat Parameters and Lifecycle Together

- Load and validate parameters before activation.
- If parameters may change between configure and activate, make the intended behavior explicit.
- Avoid parameter changes that leave a configured node internally inconsistent.
- If a parameter requires full reconfiguration, prefer a transition-driven reconfigure path rather than ad hoc mutation.

## Review Heuristics

Look for:

- lifecycle nodes introduced without any real deployment need
- transitions whose purpose is unclear or duplicated
- publishers or command paths still active while the node is inactive
- transition failures that log vaguely or not at all
- partial activation with no rollback or cleanup plan
- launch files that assume activation occurred without checking
- parameter changes that bypass the lifecycle contract

## Quick Checklist

- [ ] Lifecycle was chosen for a real operational reason.
- [ ] Each transition has a concrete responsibility.
- [ ] Inactive state truly suppresses active outputs.
- [ ] Transition failures are explicit and observable.
- [ ] Cleanup and shutdown leave the node in a known state.
- [ ] Launch and supervision flows match the lifecycle contract.
- [ ] Parameter handling is consistent with transition boundaries.