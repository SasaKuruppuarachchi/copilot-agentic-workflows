---
name: ros2-best-practices
description: Practical guidance for designing, implementing, reviewing, and operating general ROS 2 packages, nodes, launch files, parameters, QoS, and interfaces on Humble-era systems.
license: "See repository LICENSE"
user-invocable: false
---

# ROS 2 Best Practices

Use this skill when building or reviewing general ROS 2 application code and package structure. This is the broad baseline skill for everyday ROS 2 work.

Primary target: ROS 2 Humble on Ubuntu 22.04 unless the user says otherwise. When distro guidance differs, prefer Humble APIs, Humble defaults, and Humble documentation over Rolling-era examples.

Use narrower skills when the task is more specific:

- Use `ros2-cpp-patterns` for day-to-day `rclcpp` node design, package layout, callbacks, and C++ ownership boundaries.
- Use `ros2-python-patterns` for `rclpy` node structure, packaging, parameters, and callback design.
- Use `ros2-lifecycle-patterns` for managed nodes, activation/deactivation, and lifecycle-aware launch sequencing.
- Use `ros2-control-best-practices` for `ros2_control`, controller-manager setup, hardware interfaces, and controller launch/runtime behavior.
- Use `ros2-testing-qa` for launch tests, parameter verification, QoS-sensitive integration tests, and ROS 2 runtime checks.
- Use `realtime-ros2-optimization` for deterministic control loops, bounded-latency sensor processing, and allocator-sensitive code.
- Use `ros1-to-ros2-migration` for catkin-to-ament migration, API porting, `ros1_bridge`, and launch/interface migration.

## Priorities

Apply these in order:

1. **Correct Behavior**: Preserve or define the node's actual runtime behavior before chasing abstractions.
2. **Distro-Correct Usage**: Match the ROS 2 distro in use; avoid mixing Humble and newer guidance casually.
3. **Clear Communication Semantics**: Be explicit about QoS, parameters, services, actions, and namespaces.
4. **Operational Simplicity**: Make packages installable, launchable, debuggable, and inspectable with standard ROS 2 tools.
5. **Incremental Architecture**: Refactor into composition, lifecycle, or more elaborate patterns only when the task needs them.

## Core Rules

### 1. Target a Specific ROS 2 Distro

- Always anchor advice to the actual ROS 2 distro instead of generic "ROS 2" guidance.
- For Humble, prefer Humble documentation and examples. Newer docs often assume APIs, defaults, or tooling behavior that did not exist in Humble.
- If the codebase targets multiple distros, document the lowest supported distro and avoid silently depending on newer behavior.
- Do not paste Rolling or Jazzy snippets into a Humble codebase without checking package versions, launch behavior, and API availability.

### 2. Keep Build and Install Rules Correct

- Use `ament_cmake` for C++ packages and `ament_python` for pure Python packages.
- Build with `colcon`; verify the package runs from the install space, not only from the source tree.
- During active development, prefer `colcon build --symlink-install` so Python, launch, and config changes are visible immediately.
- Install launch files, parameter YAML, RViz configs, meshes, and other runtime assets explicitly.
- Keep `package.xml` dependencies accurate: `build_depend`, `exec_depend`, and interface/runtime dependencies should reflect actual usage.
- Prefer one package per coherent responsibility. Split message/service/action definitions into their own package when multiple packages consume them.

```cmake
install(DIRECTORY launch config rviz
  DESTINATION share/${PROJECT_NAME}
)
```

### 3. Design Nodes Around Clear Ownership

- A node should own one coherent responsibility: driver, estimator, planner adapter, controller wrapper, broadcaster, or orchestration boundary.
- Prefer explicit `Node` subclasses over scattered free functions and hidden global state.
- Keep transport concerns, parameter loading, and domain logic understandable from one file or one tightly related module set.
- If a node starts accumulating unrelated responsibilities, split it before adding more callbacks.
- Composition is useful, but it is not mandatory for every ROS 2 node. Start with a normal executable unless the deployment needs dynamic loading or in-process composition.

```cpp
class StatusPublisher : public rclcpp::Node {
public:
    StatusPublisher()
    : rclcpp::Node("status_publisher")
    {
        publisher_ = this->create_publisher<std_msgs::msg::String>("status", 10);
        timer_ = this->create_wall_timer(
            std::chrono::seconds(1),
            std::bind(&StatusPublisher::publish_status, this));
    }

private:
    void publish_status();

    rclcpp::Publisher<std_msgs::msg::String>::SharedPtr publisher_;
    rclcpp::TimerBase::SharedPtr timer_;
};
```

### 4. Be Explicit About Execution and Concurrency

- `rclcpp::spin(node)` behaves like a single-threaded executor. Do not assume background parallelism.
- If concurrency matters, design callback groups and executor choice together rather than adding `MultiThreadedExecutor` as a guess.
- Avoid blocking inside subscription, timer, service, or action callbacks unless you have explicitly designed around executor behavior.
- Long-running work should move out of hot callbacks into worker threads, queued jobs, or asynchronous continuations.
- If ordering matters, make that ordering explicit in your code; do not rely on executor scheduling side effects.

### 5. Treat QoS as API Surface

- In ROS 2, topic behavior is not defined by queue depth alone. Reliability, durability, history, and depth all affect interoperability.
- Choose QoS intentionally for public topics and document non-default choices.
- For high-rate sensor streams, shallow queues and `SensorDataQoS` are often a better default than deep reliable buffering.
- For "latest known state" topics that replace ROS 1 latching, use `Transient Local` durability and verify both endpoints are compatible.
- If publishers and subscribers are not communicating, inspect QoS compatibility before assuming a logic bug.

```cpp
auto qos = rclcpp::QoS(rclcpp::KeepLast(1)).reliable().transient_local();
status_pub_ = this->create_publisher<std_msgs::msg::String>("status", qos);
```

### 6. Use the Right Communication Primitive

- Use topics for continuous streams and event notifications.
- Use services for quick request/response work that should finish promptly and has no progress reporting.
- Use actions for long-running, cancelable, or progress-reporting workflows.
- Do not tunnel everything through services just because the call site wants a return value.
- Prefer asynchronous service and action clients inside callbacks. Blocking waits can deadlock or starve other work.

### 7. Manage Parameters Deliberately

- ROS 2 parameters are per-node; there is no ROS 1-style global parameter server contract.
- Declare parameters before reading them.
- Put stable defaults in code and deployment-specific overrides in YAML.
- Use parameter callbacks or validation logic for settings that must stay within a valid range.
- Treat `use_sim_time` as a per-node deployment concern and verify every time-sensitive node is configured consistently.

```cpp
publish_rate_hz_ = this->declare_parameter<double>("publish_rate_hz", 10.0);
frame_id_ = this->declare_parameter<std::string>("frame_id", "map");
```

```yaml
/status_publisher:
  ros__parameters:
    publish_rate_hz: 10.0
    frame_id: map
```

### 8. Keep Launch Files Focused on Wiring

- Launch should assemble processes, namespaces, remaps, parameters, and lifecycle order, not hide core business logic.
- Use XML or YAML launch when the configuration is mostly static; use Python launch when logic is genuinely needed.
- Keep parameters attached to the nodes that own them.
- Prefer small reusable launch files over one giant launch entry point with many conditionals.
- When introducing namespaces, verify topics, TF frame names, parameters, and service names still match expectations.

### 9. Design Stable Interfaces and Names

- Topic names, service names, action names, frame IDs, and parameter names are part of the integration contract.
- Avoid churn in interface names unless there is a real compatibility or clarity problem.
- Use message definitions that reflect domain meaning, not transport convenience.
- If an interface is shared across packages, move it into a dedicated interface package instead of creating circular dependencies.
- Keep namespaced deployments consistent. Mixing relative and absolute topic names casually creates integration bugs.

### 10. Make Nodes Operable in Production

- Use ROS 2 logging instead of `std::cout` or `print` for operational output.
- Log meaningful state transitions, startup failures, degraded modes, and external dependency problems.
- Wait for required services or action servers with bounded retries and useful logs.
- Fail fast on missing required configuration instead of silently falling back to unsafe defaults.
- Support clean shutdown: stop worker threads, release hardware handles, cancel timers, and let executors exit cleanly.

```python
while not client.wait_for_service(timeout_sec=1.0):
    node.get_logger().warning('controller service not available yet')

future = client.call_async(request)
```

### 11. Test and Inspect the Real Runtime Behavior

- Prefer small smoke tests and launch tests over assuming a node works because it compiles.
- Validate runtime behavior with standard tools such as `ros2 node info`, `ros2 topic info`, `ros2 param dump`, and `ros2 doctor`.
- When debugging communication, inspect both the graph and the QoS settings.
- Add regression tests for message conversions, parameter validation, launch wiring, and failure paths when those are part of the task.
- For hardware-facing nodes, verify startup, reconnect, and shutdown behavior explicitly.

## Review Heuristics

Look for:

- package assets that are used at runtime but never installed
- nodes that combine unrelated responsibilities and are hard to reason about
- implicit executor or callback ordering assumptions
- blocking calls inside callbacks without concurrency design
- default QoS used on important public topics without justification
- undeclared or weakly validated parameters
- giant Python launch files that mostly encode static wiring
- relative and absolute topic names mixed inconsistently
- logs that are too noisy in steady state or too vague during failure
- code that works from the source tree but breaks after `colcon build`

## Quick Checklist

- [ ] The package builds and runs correctly from the install space.
- [ ] Runtime assets are installed explicitly.
- [ ] Node responsibilities are coherent and easy to follow.
- [ ] QoS choices are deliberate for externally consumed topics.
- [ ] Parameters are declared, validated where necessary, and attached to owning nodes.
- [ ] Launch files mainly wire the system together rather than hiding application logic.
- [ ] Namespaces, topic names, frame IDs, and parameter names are consistent.
- [ ] Blocking work is not hidden inside callbacks by accident.
- [ ] Logs and startup failures are operationally useful.
- [ ] Narrower ROS 2 skills are used when the task is really migration-specific or real-time-specific.

## Good Pairings

- Pair with `ros2-cpp-patterns` for implementation details in `rclcpp` packages.
- Pair with `ros2-python-patterns` for implementation details in `rclpy` packages.
- Pair with `ros2-lifecycle-patterns` when startup, activation, and managed-state transitions matter.
- Pair with `ros2-control-best-practices` for controller-manager, hardware-interface, and controller configuration work.
- Pair with `ros2-testing-qa` when changing launch wiring, parameters, QoS, or integration behavior.
- Pair with `testing-qa` for general non-ROS-specific verification discipline.
- Pair with `code-quality` for implementation and refactoring decisions outside ROS-specific concerns.
- Pair with `security-best-practices` for robot APIs that cross process, network, or trust boundaries.
- Escalate to `realtime-ros2-optimization` for strict latency and determinism requirements.
- Escalate to `ros1-to-ros2-migration` for phased ports and compatibility planning.