---
name: ros2-python-patterns
description: Practical Python patterns for ROS 2 Humble nodes, packages, launch integration, parameters, services, and runtime behavior using rclpy.
license: "See repository LICENSE"
user-invocable: false
---

# ROS 2 Python Patterns

Use this skill when implementing or reviewing ROS 2 Python code with `rclpy`. This is the narrower follow-on skill for day-to-day Python node structure, package layout, callback design, and deployment behavior.

Primary target: ROS 2 Humble on Ubuntu 22.04 unless the user says otherwise.

Use other ROS skills when the task is narrower:

- Use `ros2-testing-qa` for launch tests, runtime verification, parameter-validation tests, and graph checks.
- Use `ros2-lifecycle-patterns` when managed-node state transitions are part of the design.
- Use `realtime-ros2-optimization` for strict jitter, bounded-latency, or allocation-sensitive control code.
- Use `ros1-to-ros2-migration` for `rospy` migration and phased interop.

## Priorities

Apply these in order:

1. **Clear Node Ownership**: Make each node's responsibility and state transitions obvious.
2. **Installable Python Packaging**: Ensure entry points and runtime assets work from the install space.
3. **Predictable Callback Behavior**: Keep callbacks short and avoid accidental executor problems.
4. **Explicit Configuration**: Declare, validate, and document parameters clearly.
5. **Operational Readability**: Prefer straightforward code and useful logs over clever framework indirection.

## Core Rules

### 1. Use `Node` Subclasses, Not Script-Style Globals

- Model each ROS 2 Python node as a `Node` subclass.
- Keep publishers, subscriptions, timers, clients, and services as instance members.
- Avoid module-level mutable state and long setup scripts that hide ownership.
- If a node does too many unrelated jobs, split it before adding more callbacks.

```python
import rclpy
from rclpy.node import Node
from std_msgs.msg import String


class HeartbeatNode(Node):
    def __init__(self) -> None:
        super().__init__('heartbeat_node')
        self.interval_sec = self.declare_parameter('interval_sec', 1.0).value
        self.publisher = self.create_publisher(String, 'heartbeat', 10)
        self.timer = self.create_timer(self.interval_sec, self.on_timer)

    def on_timer(self) -> None:
        msg = String()
        msg.data = 'alive'
        self.publisher.publish(msg)
```

### 2. Package Python Nodes for the Install Space

- Pure Python ROS 2 packages should use `ament_python`.
- Define `console_scripts` entry points instead of relying on ad hoc executable scripts.
- Install launch files, config YAML, and other runtime assets explicitly.
- Verify the package runs after `colcon build`, not just when invoked from the source tree.

```python
from setuptools import setup

package_name = 'my_py_pkg'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    install_requires=['setuptools'],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        ('share/' + package_name + '/launch', ['launch/app.launch.py']),
        ('share/' + package_name + '/config', ['config/default.yaml']),
    ],
    entry_points={
        'console_scripts': [
            'heartbeat_node = my_py_pkg.heartbeat:main',
        ],
    },
)
```

### 3. Keep Callbacks Thin and Non-Blocking

- Subscription, timer, and service callbacks should update state, publish output, or hand work off.
- Avoid large orchestration blocks or blocking waits inside callbacks.
- If a callback needs long-running work, move it to a worker or use asynchronous completion paths.
- Do not assume `rclpy.spin(node)` gives you background concurrency for free.

### 4. Centralize Parameter Declaration and Validation

- Declare parameters during node initialization.
- Keep defaults in code and deployment overrides in YAML.
- Convert and validate values once instead of re-reading raw parameters throughout the code path.
- If a parameter controls a runtime behavior boundary, log the chosen value at startup.

```python
rate_hz = self.declare_parameter('rate_hz', 10.0).value
if rate_hz <= 0.0:
    raise ValueError('rate_hz must be > 0')
```

### 5. Prefer Async Service and Action Usage

- Prefer `call_async()` and completion handling over blocking request/response inside callbacks.
- Wait for required services with bounded retries and useful logs.
- Treat actions as the default for long-running or cancelable work rather than stretching services beyond their shape.

```python
while not self.client.wait_for_service(timeout_sec=1.0):
    self.get_logger().warning('planner service not available yet')

future = self.client.call_async(request)
```

### 6. Keep Launch and Python Logic Separate

- Launch files should wire nodes, parameters, remaps, and namespaces together.
- Business logic belongs in the node implementation, not in dynamic launch-time Python when it can be avoided.
- Keep launch files small and reusable.
- If the runtime shape is static, XML or YAML launch can be simpler than Python launch.

### 7. Be Honest About Concurrency and Threading

- Default `rclpy.spin(node)` execution is easiest to reason about and should be the baseline.
- If you introduce executors or background threads, make shared-state ownership explicit.
- Avoid mixing timers, subscriptions, and worker threads around mutable shared state without a clear design.
- If callback-group behavior or strict timing matters, escalate to the more specific ROS 2 executor or realtime skills.

### 8. Keep Logging and Shutdown Operationally Useful

- Use ROS 2 logging rather than bare `print()` for operational messages.
- Log startup configuration, degraded modes, and external dependency failures clearly.
- Shut down cleanly with `rclpy.try_shutdown()` and release worker resources deterministically.
- Do not swallow exceptions that should fail startup.

## Review Heuristics

Look for:

- Python nodes implemented as large procedural scripts instead of coherent classes
- packages that define entry points incorrectly or forget to install launch/config assets
- blocking waits inside callbacks
- repeated raw parameter reads and weak validation
- broad use of threads without a clear shared-state policy
- launch files carrying business logic that belongs in the node
- logs that are noisy during steady state but vague during startup failure

## Quick Checklist

- [ ] The node is structured as a coherent `Node` subclass.
- [ ] Entry points and runtime assets work from the install space.
- [ ] Callbacks stay short and non-blocking.
- [ ] Parameters are declared and validated centrally.
- [ ] Service and action interactions are asynchronous where appropriate.
- [ ] Launch wiring stays separate from application logic.
- [ ] Threading and executor assumptions are explicit.
- [ ] Logging and shutdown behavior are operationally clear.