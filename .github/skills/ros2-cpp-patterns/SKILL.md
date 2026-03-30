---
name: ros2-cpp-patterns
description: Practical C++ patterns for ROS 2 Humble nodes, packages, callbacks, parameters, components, and resource ownership using rclcpp.
license: "See repository LICENSE"
user-invocable: false
---

# ROS 2 C++ Patterns

Use this skill when implementing or reviewing ROS 2 C++ code with `rclcpp`. This is the narrower follow-on skill for day-to-day ROS 2 C++ design, package structure, and node implementation.

Primary target: ROS 2 Humble on Ubuntu 22.04 unless the user says otherwise.

Use other ROS skills when the task is narrower:

- Use `realtime-ros2-optimization` for strict latency, deterministic execution, callback-group strategy, and allocation-sensitive hot paths.
- Use `ros2-testing-qa` for launch tests, graph verification, process orchestration checks, and regression coverage strategy.
- Use `ros1-to-ros2-migration` for API porting from `roscpp` or catkin-era package structure.

## Priorities

Apply these in order:

1. **Clear Ownership**: Make node responsibilities, resources, and data flow obvious.
2. **Safe Runtime Behavior**: Keep callbacks short, explicit, and operationally predictable.
3. **Distro-Correct APIs**: Use Humble-compatible `rclcpp` APIs and package conventions.
4. **Installable Package Structure**: Build and install targets and assets correctly.
5. **Incremental Abstraction**: Add components, helper layers, and generic utilities only when they reduce real complexity.

## Core Rules

### 1. Prefer Cohesive `Node` Classes

- Model each node as a class inheriting from `rclcpp::Node` unless there is a strong reason not to.
- Keep one node focused on one coherent responsibility.
- Store publishers, subscriptions, timers, clients, services, and callback groups as members.
- Avoid hidden global state, file-scope singletons, and helper functions that mutate shared node state indirectly.
- If logic grows beyond a readable node class, extract pure helpers or small collaborators rather than piling more callbacks into the node.

```cpp
class HeartbeatNode : public rclcpp::Node {
public:
    HeartbeatNode()
    : rclcpp::Node("heartbeat_node")
    {
        interval_ms_ = this->declare_parameter<int>("interval_ms", 1000);
        publisher_ = this->create_publisher<std_msgs::msg::String>("heartbeat", 10);
        timer_ = this->create_wall_timer(
            std::chrono::milliseconds(interval_ms_),
            std::bind(&HeartbeatNode::on_timer, this));
    }

private:
    void on_timer();

    int interval_ms_;
    rclcpp::Publisher<std_msgs::msg::String>::SharedPtr publisher_;
    rclcpp::TimerBase::SharedPtr timer_;
};
```

### 2. Keep Package and Target Layout Boring

- Use `ament_cmake` and modern target-based CMake.
- Put public headers under `include/${PROJECT_NAME}/` and install them only when other targets need them.
- Install executables, launch files, config, and other runtime assets explicitly.
- Keep dependencies target-local; avoid broad global include and link settings.
- If messages, services, or actions are reused by multiple packages, move them into a dedicated interface package instead of keeping everything together.

```cmake
add_executable(heartbeat_node src/heartbeat_node.cpp)
target_include_directories(heartbeat_node PUBLIC
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
  "$<INSTALL_INTERFACE:include/${PROJECT_NAME}>"
)
ament_target_dependencies(heartbeat_node rclcpp std_msgs)

install(TARGETS heartbeat_node DESTINATION lib/${PROJECT_NAME})
install(DIRECTORY launch config DESTINATION share/${PROJECT_NAME})
```

### 3. Keep Callbacks Thin

- Subscription, timer, service, and action callbacks should do only the work needed to update state, publish output, or hand work off.
- Avoid large orchestration blocks inside callbacks.
- Parse, validate, and transform data in helpers that can be tested outside the executor.
- If a callback starts performing multiple distinct responsibilities, split the work into explicit methods.
- Avoid blocking calls in callbacks unless the executor model was designed to allow it safely.

### 4. Make Data Ownership Explicit

- In subscription callbacks, prefer receiving `SharedPtr` or `ConstSharedPtr` and copy only when long-lived ownership is actually needed.
- Do not cache pointers to data whose lifetime you do not control.
- Prefer value types for stable internal state and explicit copies at boundaries.
- Avoid passing mutable shared state through many helpers; return values or update small owned structs instead.
- For large payloads or performance-sensitive code, document ownership expectations instead of relying on convention.

```cpp
void on_message(const std_msgs::msg::String::ConstSharedPtr msg)
{
    latest_text_ = msg->data;
    maybe_publish_status();
}
```

### 5. Declare and Validate Parameters at the Boundary

- Declare every parameter before use.
- Keep defaults in code and deployment-specific values in YAML.
- Validate ranges and enumerations close to parameter ingestion.
- Do not scatter raw parameter lookups across the code path.
- When parameter changes affect runtime state, centralize the update path so the node does not drift into partially updated state.

```cpp
max_queue_depth_ = this->declare_parameter<int>("max_queue_depth", 10);
if (max_queue_depth_ < 1) {
    throw std::invalid_argument("max_queue_depth must be >= 1");
}
```

### 6. Separate ROS Wiring from Domain Logic

- Message conversion, transport setup, and parameter plumbing are ROS-facing concerns.
- Keep domain calculations, validation rules, and state machines separable from `rclcpp` where practical.
- Prefer helpers that operate on plain C++ data when the logic does not need ROS types directly.
- This makes unit testing cheaper and reduces the amount of code coupled to executors, clocks, or node state.

### 7. Use Composition Deliberately

- Components are useful when deployment needs in-process composition or dynamic loading.
- Do not force every node into component form on day one.
- If you expose a component, keep the normal node constructor readable and make startup behavior equivalent between the standalone and component forms.
- Register components explicitly and keep side effects out of static initialization.

```cpp
#include "rclcpp_components/register_node_macro.hpp"

RCLCPP_COMPONENTS_REGISTER_NODE(HeartbeatNode)
```

### 8. Fail Early on Broken Startup, Stay Predictable Afterward

- Validate required parameters, external connections, and file paths during startup.
- Use `RCLCPP_INFO`, `RCLCPP_WARN`, and `RCLCPP_ERROR` for operationally meaningful events.
- Do not silently fall back to surprising defaults when startup requirements are missing.
- Ensure shutdown paths stop timers, worker threads, and external resources cleanly.
- If a dependency is optional, log that degraded mode explicitly.

### 9. Keep Concurrency Explicit, Not Accidental

- Default `rclcpp::spin(node)` execution is single-threaded.
- If you introduce `MultiThreadedExecutor`, also design callback groups and shared-state rules explicitly.
- Use mutexes sparingly and keep lock scope small.
- If strict callback ordering or latency bounds matter, escalate to `realtime-ros2-optimization` instead of hand-waving around executor behavior.

## Review Heuristics

Look for:

- node classes that own too many unrelated concerns
- executables that work from the source tree but do not install the assets they need
- callbacks that contain large business flows or blocking waits
- undeclared parameters or weak parameter validation
- mutable shared state passed across many helpers with unclear ownership
- components added for fashion rather than a deployment need
- startup code that logs an error but keeps running in a broken state
- `MultiThreadedExecutor` introduced without callback-group design

## Quick Checklist

- [ ] Node ownership boundaries are clear.
- [ ] Package targets and runtime assets install correctly.
- [ ] Callbacks are short and readable.
- [ ] Data ownership is explicit at ROS boundaries.
- [ ] Parameters are declared and validated centrally.
- [ ] Domain logic is not unnecessarily tangled with ROS wiring.
- [ ] Componentization is used only when deployment benefits from it.
- [ ] Startup and shutdown behavior are operationally explicit.
- [ ] Concurrency choices are deliberate rather than accidental.