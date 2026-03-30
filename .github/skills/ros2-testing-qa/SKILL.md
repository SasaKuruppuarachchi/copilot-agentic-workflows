---
name: ros2-testing-qa
description: Practical testing and launch-testing guidance for ROS 2 Humble packages, nodes, parameters, QoS, graph wiring, and runtime behavior.
license: "See repository LICENSE"
user-invocable: false
---

# ROS 2 Testing & QA

Use this skill when adding or reviewing tests for ROS 2 packages, nodes, launch files, parameters, services, actions, and integration wiring. This is the narrower follow-on skill for ROS-specific verification strategy.

Primary target: ROS 2 Humble on Ubuntu 22.04 unless the user says otherwise.

Use other ROS skills when the task is narrower:

- Use `ros2-best-practices` for broad package, launch, QoS, and node-structure guidance.
- Use `ros2-cpp-patterns` for C++ node design and testable `rclcpp` implementation structure.
- Use `realtime-ros2-optimization` when latency, jitter, deadlines, or allocator behavior are part of the acceptance criteria.

## Priorities

Apply these in order:

1. **Test Observable Runtime Behavior**: Verify the node graph, messages, parameters, and process lifecycle that actually matter.
2. **Keep Tests Deterministic**: Bound waits, control startup order, and avoid timing guesswork.
3. **Use the Smallest Useful Scope**: Prefer unit and focused integration tests before broad launch tests.
4. **Match ROS 2 Failure Modes**: Cover QoS mismatch, bad parameters, missing services, namespace wiring, and startup errors when relevant.
5. **Keep Verification Operational**: Use standard ROS 2 tools and launch checks to prove the deployed system really works.

## Core Rules

### 1. Start Below the Executor When You Can

- Put pure parsing, mapping, filtering, and state-transition logic behind unit-testable helpers.
- Do not force every behavior through a spinning node test if the logic does not need ROS runtime context.
- Use unit tests for conversions, validators, command shaping, and state transitions.
- This keeps the slowest and flakiest layer focused on the parts that actually need ROS.

### 2. Use Integration Tests for Real ROS Contracts

- Add integration tests when behavior depends on publishers, subscriptions, services, actions, parameters, or executors.
- Prefer realistic wiring with a small number of actual nodes over over-mocked tests that prove little.
- Test public contracts: published messages, service responses, action outcomes, parameter effects, and startup failures.
- For C++ packages, use `ament_add_gtest`; for Python-based verification, use `ament_add_pytest_test` or package-native test runners.

```cmake
find_package(ament_cmake_gtest REQUIRED)

ament_add_gtest(test_parameter_validation test/test_parameter_validation.cpp)
ament_target_dependencies(test_parameter_validation rclcpp std_msgs)
```

### 3. Use Launch Tests for Process Wiring and Deployment Behavior

- Use launch tests when you need to verify executables start, parameters load, remaps apply, namespaces resolve, or services/actions become available.
- Keep launch tests focused on startup and system wiring, not every downstream behavior.
- Prefer one launch test per meaningful deployment scenario instead of one giant all-system script.
- If the bug only appears when the node is launched the real way, a launch test is usually the right regression guard.

```python
import launch
import launch_ros.actions
import launch_testing


def generate_test_description():
    node = launch_ros.actions.Node(
        package='my_pkg',
        executable='my_node',
        parameters=['config/test_params.yaml'],
        output='screen',
    )
    return launch.LaunchDescription([
        node,
        launch_testing.actions.ReadyToTest(),
    ]), {'node': node}
```

### 4. Bound Waiting and Avoid Sleep-Driven Tests

- Avoid raw `sleep()` calls as the main synchronization mechanism.
- Wait on explicit conditions: service availability, future completion, message arrival, process start, or process exit.
- Use bounded timeouts and fail with useful context.
- When timing matters, make the expected condition visible rather than hoping enough time elapsed.

### 5. Verify QoS and Graph Behavior Deliberately

- ROS 2 communication bugs are often graph or QoS bugs, not algorithm bugs.
- When a test exercises a topic contract, verify the publisher and subscriber can actually match.
- Add targeted tests for latched-like `Transient Local` topics, best-effort sensor streams, or custom QoS only when those contracts matter.
- If a node should expose a service, action, or parameter namespace after startup, assert that explicitly.

### 6. Test Parameters as Behavior, Not Just Configuration Files

- Cover both valid and invalid parameter cases when parameters affect behavior materially.
- Verify startup failure on missing required parameters when that is the intended contract.
- Verify that parameter overrides from launch or YAML take effect in the running node.
- If dynamic parameter updates are supported, test both accepted and rejected updates.

### 7. Keep Hardware and Simulation Boundaries Honest

- Do not pretend hardware-dependent code is fully unit tested if the real risk is startup, reconnect, or degraded-mode behavior.
- For hardware-facing nodes, add smoke tests or manual verification steps for connect, disconnect, timeout, and shutdown paths.
- For simulated systems, verify `use_sim_time`, `/clock` behavior, and namespace wiring when those are part of the deployment contract.
- Use fakes or test adapters where possible, but keep them behaviorally close to the real boundary.

### 8. Use CLI Verification as a First-Class Supplement

- `ros2 node list`, `ros2 node info`, `ros2 topic list`, `ros2 topic info`, `ros2 param list`, and `ros2 param dump` are valid verification tools.
- Manual smoke verification is appropriate for launch wiring, namespace problems, and environment-specific behavior that is too expensive to automate immediately.
- If automation is not practical yet, write down the exact manual checks rather than saying "tested manually" without detail.

## Review Heuristics

Look for:

- ROS-heavy tests that should have been simple unit tests
- launch tests that try to validate too many unrelated behaviors at once
- tests that rely on fixed sleeps instead of observable readiness
- no coverage for parameter failure or startup misconfiguration paths
- no regression guard for QoS-sensitive or namespace-sensitive behavior
- mocks that replace the exact ROS contract the test needed to prove
- tests that pass only from the source tree and not from installed artifacts

## Quick Checklist

- [ ] The test scope matches the changed ROS behavior.
- [ ] Launch tests are used only where real process wiring must be proved.
- [ ] Waits are bounded and driven by observable readiness.
- [ ] Parameter and startup failure paths are covered when relevant.
- [ ] QoS and graph assumptions are checked for externally consumed contracts.
- [ ] Manual ROS 2 CLI verification steps are documented when automation is insufficient.
- [ ] Tests exercise installed launch/config assets when deployment wiring matters.

## Good Pairings

- Pair with `testing-qa` for general verification discipline and test-scope decisions.
- Pair with `ros2-best-practices` when the test plan depends on launch, parameters, namespaces, or QoS design.
- Pair with `ros2-cpp-patterns` when testability depends on how the `rclcpp` node is structured.
- Escalate to `realtime-ros2-optimization` when timing guarantees themselves must be verified.