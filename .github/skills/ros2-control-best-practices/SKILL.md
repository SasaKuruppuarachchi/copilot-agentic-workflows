---
name: ros2-control-best-practices
description: Practical guidance for designing, configuring, and reviewing ros2_control systems, controller_manager setup, hardware interfaces, controllers, and launch/runtime behavior on Humble.
license: "See repository LICENSE"
user-invocable: false
---

# ros2_control Best Practices

Use this skill when working on `ros2_control` hardware interfaces, controller configuration, controller-manager setup, launch sequencing, and runtime behavior. This is the narrower skill for managed control systems beyond the generic ROS 2 baseline.

Primary target: ROS 2 Humble on Ubuntu 22.04 unless the user says otherwise.

Use other ROS skills when the task is narrower:

- Use `realtime-ros2-optimization` for strict control-loop latency, callback-group strategy, memory constraints, and scheduler tuning.
- Use `ros2-lifecycle-patterns` when managed-node transitions or activation sequencing are the main design issue.
- Use `ros2-testing-qa` for controller launch tests, parameter validation, and runtime verification.

## Priorities

Apply these in order:

1. **Safe Control Behavior**: Controllers and hardware interfaces must fail predictably, not optimistically.
2. **Clear Resource Ownership**: Command and state interfaces should be explicit and non-ambiguous.
3. **Deterministic Startup Sequencing**: Hardware, controller manager, broadcasters, and controllers should come up in a deliberate order.
4. **Operational Debuggability**: Configuration, activation, and degraded states must be observable.
5. **Humble-Correct Configuration**: Match Humble-era controller-manager and ros2_control behavior.

## Core Rules

### 1. Keep Hardware Interfaces Honest

- Hardware-interface code should reflect the real timing, command, and feedback boundaries of the device.
- Do not fake successful reads or writes when transport or hardware state is unknown.
- Expose only the command and state interfaces the hardware truly supports.
- Keep transport setup, unit conversion, and protocol parsing understandable and auditable.

### 2. Make Resource and Interface Contracts Explicit

- Define command and state interfaces clearly in URDF and hardware code.
- Use stable interface naming and avoid ambiguous ownership between multiple controllers.
- If multiple controllers may contend for resources, make controller switching and claims explicit.
- Avoid hidden coupling where one controller assumes another already populated some state.

### 3. Separate Controller Configuration from Hardware Logic

- Hardware plugins should focus on device interaction.
- Controller YAML should define controller selection, types, and parameters clearly.
- Keep controller-manager configuration readable rather than burying settings across many files.
- If the setup needs many controllers and broadcasters, group them coherently by role.

```yaml
controller_manager:
  ros__parameters:
    update_rate: 250
    joint_state_broadcaster:
      type: joint_state_broadcaster/JointStateBroadcaster
    arm_controller:
      type: joint_trajectory_controller/JointTrajectoryController
```

### 4. Bring Systems Up in a Deliberate Order

- Start hardware and `controller_manager` before spawning dependent controllers.
- Bring up state broadcasters before controllers that operators rely on for observability.
- Do not assume launch parallelism yields a safe startup sequence.
- If activation or spawner timing matters, make that ordering explicit in launch or orchestration.

### 5. Treat Controller Manager as an Operational Boundary

- `controller_manager` is part of the runtime contract, not just a helper process.
- Log and monitor controller load, configure, activate, and switch failures clearly.
- Keep update rate explicit and consistent with the hardware and controller design.
- For strict jitter requirements, pair this skill with `realtime-ros2-optimization` rather than treating ros2_control tuning as a generic ROS problem.

### 6. Validate Commands and Degraded Modes Explicitly

- Check command ranges, interface availability, and hardware state before sending outputs.
- If a controller or hardware component enters a degraded mode, make that visible in logs and system state.
- Prefer safe refusal over silently accepting commands that cannot be executed correctly.
- Keep emergency-stop or command-suppression paths explicit and testable.

### 7. Keep Simulation and Hardware Paths Comparable, Not Identical by Force

- Simulation and hardware backends should expose compatible interfaces, but they do not need to share every implementation detail.
- Do not let simulation shortcuts hide hardware timing, activation, or fault-handling risks.
- When using fake or simulated hardware for tests, document the gaps relative to the real device.

### 8. Make Launch and Parameters Reviewable

- Controller YAML should be compact, intentional, and easy to audit.
- Avoid giant parameter blobs with unclear ownership between hardware, controller manager, and controllers.
- Keep robot description, controller-manager arguments, spawners, and controller YAML wiring obvious in launch.
- If a startup issue depends on launch order or parameter file selection, capture that explicitly in tests or manual verification.

## Review Heuristics

Look for:

- hardware interfaces that report success even when device state is uncertain
- unclear or conflicting ownership of command/state interfaces
- controller-manager startup that depends on fragile timing instead of explicit sequencing
- controller YAML spread across too many files with unclear boundaries
- degraded modes that only log generic errors or keep issuing commands
- simulated setups that mask hardware-specific safety or timing assumptions
- strict latency requirements handled without consulting the realtime skill

## Quick Checklist

- [ ] Hardware interfaces reflect real device capabilities and failure modes.
- [ ] Command and state interface ownership is explicit.
- [ ] Controller-manager update rate and controller setup are deliberate.
- [ ] Startup and activation order are explicit.
- [ ] Degraded-mode and refusal behavior are visible and safe.
- [ ] Launch and parameter wiring are reviewable.
- [ ] Simulation paths do not hide hardware-specific risks.
- [ ] Realtime concerns are escalated when control jitter matters.