---
name: ros1-to-ros2-migration
description: Rules for migrating ROS 1 packages, nodes, launch files, parameters, nodelets, and catkin builds to ROS 2 using rclcpp, rclpy, ament, and ros1_bridge where needed.
license: "See repository LICENSE"
user-invocable: false
---

# ROS 1 to ROS 2 Migration

Use this skill to port legacy ROS 1 packages to ROS 2 with the smallest safe behavioral change first, then refactor toward ROS 2-native structure. Primary target: ROS 2 Humble on Ubuntu 22.04 unless the user says otherwise.

## Priorities

1. **Behavioral Parity**: Get the package building and behaving correctly before architectural cleanup.
2. **Build and Install Correctness**: `colcon`, `ament_*`, install rules, and entry points must be right.
3. **Communication Semantics**: Re-evaluate QoS, services vs actions, and parameter ownership instead of blindly translating APIs.
4. **ROS 2 Refactoring**: Move to timers, node classes, composition, and cleaner launch only after parity.
5. **Interop Strategy**: Use `ros1_bridge` deliberately when a phased migration is required.

## Core Rules

### 1. Migrate in Passes

- First migrate metadata and build files so the package can compile or install incrementally.
- Then do a mechanical API port for code paths that already exist.
- Only after tests or runtime checks pass should you refactor into components, lifecycle nodes, cleaner callback structure, or new message types.
- Do not mix feature work with migration unless the user explicitly asks for both.
- If the ROS 1 package relied on nodelets, shared memory, or tight callback ordering, call that out early because it affects the ROS 2 execution model.

### 2. Build System and Package Metadata

- Replace `catkin` with `ament_cmake` for C++ packages and `ament_python` for pure Python packages.
- Use `colcon` for builds. There is no devel space in ROS 2; packages must install correctly to run.
- ROS 2 requires `package.xml` format 2 or newer. For migration, format 2 is sufficient; format 3 is fine if the repo already uses it.
- Prefer `colcon build --symlink-install` during migration so launch files and Python code can be iterated quickly.
- For C++ packages, use modern CMake targets and per-target include directories. Do not carry over `include_directories(${catkin_INCLUDE_DIRS})` patterns.
- If a package mixes interfaces with a large amount of implementation code, consider splitting interfaces into a dedicated package.

```cmake
cmake_minimum_required(VERSION 3.14.4)
project(my_pkg)

if(NOT CMAKE_CXX_STANDARD)
    set(CMAKE_CXX_STANDARD 17)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(std_msgs REQUIRED)

add_executable(my_node src/my_node.cpp)
target_include_directories(my_node PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
    "$<INSTALL_INTERFACE:include/${PROJECT_NAME}>")
target_link_libraries(my_node PUBLIC
    rclcpp::rclcpp
    ${std_msgs_TARGETS})

install(TARGETS my_node DESTINATION lib/${PROJECT_NAME})

ament_package()
```

### 3. C++ Node Porting (`roscpp` -> `rclcpp`)

- Replace `ros::init()` plus `ros::NodeHandle` with `rclcpp::init()` and either `rclcpp::Node::make_shared(...)` or a class inheriting from `rclcpp::Node`.
- Change includes from `pkg/Msg.h` to `pkg/msg/my_msg.hpp`, `pkg/Srv.h` to `pkg/srv/my_srv.hpp`, and add `msg` / `srv` / `action` namespaces in code.
- Replace `ros::Time` with `rclcpp::Time` or `this->get_clock()->now()`.
- Replace `boost` utilities with the C++ standard library where possible: `std::shared_ptr`, `std::mutex`, `std::function`, `std::unordered_map`.
- Service callbacks no longer return `bool`; throw on failure or report errors explicitly.
- For the first working port, a standalone executable is fine. Converting every migrated node into a component on day one is optional, not mandatory.

```cpp
#include <chrono>
#include "rclcpp/rclcpp.hpp"
#include "std_msgs/msg/string.hpp"

class Talker : public rclcpp::Node {
public:
    Talker()
    : rclcpp::Node("talker")
    {
        publish_rate_hz_ = this->declare_parameter<double>("publish_rate_hz", 10.0);
        publisher_ = this->create_publisher<std_msgs::msg::String>("chatter", 10);
        timer_ = this->create_wall_timer(
            std::chrono::duration<double>(1.0 / publish_rate_hz_),
            std::bind(&Talker::on_timer, this));
    }

private:
    void on_timer()
    {
        std_msgs::msg::String msg;
        msg.data = "hello from ROS 2";
        RCLCPP_INFO(this->get_logger(), "%s", msg.data.c_str());
        publisher_->publish(msg);
    }

    double publish_rate_hz_;
    rclcpp::Publisher<std_msgs::msg::String>::SharedPtr publisher_;
    rclcpp::TimerBase::SharedPtr timer_;
};

int main(int argc, char ** argv)
{
    rclcpp::init(argc, argv);
    rclcpp::spin(std::make_shared<Talker>());
    rclcpp::shutdown();
    return 0;
}
```

### 4. Python Node Porting (`rospy` -> `rclpy`)

- ROS 2 Python packages are Python 3 only.
- Pure Python packages should use `ament_python`, `setup.py`, `setup.cfg`, a package marker file in `resource/`, and `console_scripts` entry points.
- As a temporary compatibility step, you can emulate ROS 1-style background callback handling with a separate executor thread. Do not keep that as the final design unless the code genuinely needs it.
- The preferred end state is a `Node` subclass with timer or subscription callbacks and `rclpy.spin(node)` on the main thread.

```python
import rclpy
from rclpy.node import Node
from std_msgs.msg import String


class Talker(Node):
    def __init__(self) -> None:
        super().__init__('talker')
        self.publisher = self.create_publisher(String, 'chatter', 10)
        self.timer = self.create_timer(0.1, self.on_timer)

    def on_timer(self) -> None:
        msg = String()
        msg.data = f'hello world {self.get_clock().now()}'
        self.get_logger().info(msg.data)
        self.publisher.publish(msg)


def main() -> None:
    rclpy.init()
    try:
        node = Talker()
        rclpy.spin(node)
    finally:
        rclpy.try_shutdown()
```

```python
from setuptools import setup

package_name = 'my_py_pkg'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    install_requires=['setuptools'],
    zip_safe=True,
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    entry_points={
        'console_scripts': [
            'my_node = my_py_pkg.main:main',
        ],
    },
)
```

### 5. Parameters and Dynamic Reconfigure Migration

- ROS 2 has no central parameter server. Parameters belong to individual nodes.
- Declare parameters before reading them.
- Nested parameter names use `.` instead of `/`.
- ROS 1 `dynamic_reconfigure` typically maps to normal ROS 2 parameters plus validation callbacks.
- If the ROS 1 code relied on grouped dynamic reconfigure updates being atomic, use `set_parameters_atomically` semantics in ROS 2.
- If a global blackboard is still needed during migration, use a dedicated parameter node instead of pretending ROS 1 `roscore` semantics still exist.

```yaml
/camera:
    ros__parameters:
        exposure: 12
        gain: 4

/**:
    ros__parameters:
        debug: true
```

### 6. Communication Semantics: Topics, Services, Actions, QoS

- Do not treat ROS 2 communication as a mechanical rename of ROS 1 publishers and subscribers.
- ROS 1 queue size maps only partially to ROS 2 QoS. In ROS 2, durability, reliability, history, and depth all matter.
- ROS 1 latched publishers map to `Transient Local` durability, but both ends must be QoS-compatible.
- Use topics for continuous streams, services for quick stateless RPC-style calls, and actions for long-running or preemptable work.
- Always wait for services before calling them.
- In callbacks, prefer asynchronous service or action usage. Blocking calls can deadlock under the ROS 2 executor model.

```cpp
// ROS 1 latched publisher equivalent in ROS 2.
auto qos = rclcpp::QoS(rclcpp::KeepLast(1)).reliable().transient_local();
publisher_ = this->create_publisher<std_msgs::msg::String>("status", qos);
```

```python
from example_interfaces.srv import AddTwoInts

client = node.create_client(AddTwoInts, 'add_two_ints')
while not client.wait_for_service(timeout_sec=1.0):
    node.get_logger().info('service not available, waiting again...')

future = client.call_async(request)
```

### 7. Launch Migration

- ROS 2 launch is not just ROS 1 XML with renamed tags.
- For easy ROS 1 XML migration, ROS 2 XML or YAML launch files are often the shortest path. Use Python launch when the launch actually needs logic.
- There is no global parameter section in ROS 2 launch. Parameters must be attached to nodes.
- `type` becomes `exec`, `ns` becomes `namespace`, and `required="true"` becomes `on_exit="shutdown"` in XML launch.
- `rosparam` becomes `<param from="..."/>` nested under a node.
- `include` scoping changed. If you want ROS 1-like namespaced include behavior, wrap the include in a `group` and use `push_ros_namespace`.

```xml
<launch>
    <group>
        <push_ros_namespace namespace="robot1"/>
        <include file="$(find-pkg-share my_pkg)/launch/drivers.launch.xml"/>
    </group>
</launch>
```

### 8. Interface Migration

- ROS 2 interface files still live in `msg/`, `srv/`, and `action/`, but the generated APIs are different.
- Replace deprecated or changed primitive usage with ROS 2 interface rules.
- `time` and `duration` are normal message types from `builtin_interfaces`.
- Interface-only packages must use `rosidl_default_generators`, `rosidl_default_runtime`, and membership in `rosidl_interface_packages`.
- Pure Python packages should not also generate interfaces; split interfaces into a CMake package.

```cmake
find_package(rosidl_default_generators REQUIRED)
find_package(std_msgs REQUIRED)

rosidl_generate_interfaces(${PROJECT_NAME}
    "msg/Foo.msg"
    "srv/DoThing.srv"
    DEPENDENCIES std_msgs
)
```

### 9. Composition and Nodelets

- Nodelets do not map 1:1 to ROS 2 components operationally.
- ROS 2 composition is powerful, but it is a deployment choice as much as a code-structure choice.
- If the ROS 1 package used nodelets only for performance, first get the ROS 2 code running in standalone form, then introduce components if profiling shows they are needed.
- If the ROS 1 package relied on shared callback queues or ordering assumptions, revisit executor and callback-group design explicitly.

### 10. Transitional Interop with `ros1_bridge`

- If the system cannot be migrated all at once, plan a bridge boundary explicitly.
- Bridge topics and services only where needed; avoid using the bridge as a permanent architecture layer.
- On Ubuntu 22.04 with ROS 2 Humble, `ros1_bridge` has packaging caveats. The official Humble guidance for upstream ROS 1 packages on Jammy relies on building ROS 2 from source rather than using the normal ROS 2 apt repo flow.
- Use the bridge to phase deployments, not to avoid fixing QoS, interface, or parameter-model differences.

## Anti-Patterns

- Rewriting architecture, behavior, and interfaces all in the same migration step.
- Forcing every migrated node to become a component immediately.
- Treating ROS 1 `queue_size` as equivalent to ROS 2 QoS.
- Preserving blocking main-loop patterns as the final ROS 2 design instead of moving work into callbacks or timers.
- Using services for long-running or preemptable operations that should be actions.
- Continuing to model parameters as a global blackboard.
- Assuming ROS 1 launch include scoping, parameter scoping, or namespace behavior still applies unchanged.
- Leaving C++ packages on catkin-era CMake patterns like global include directories and `${catkin_LIBRARIES}`.

## Quick Checklist

- [ ] `package.xml`, build tool, and install rules are valid for ROS 2.
- [ ] Pure Python packages use `ament_python`, `setup.cfg`, marker files, and `console_scripts`.
- [ ] C++ packages use `ament_cmake`, modern targets, and per-target include directories.
- [ ] Parameters are declared and YAML files use node names with `ros__parameters`.
- [ ] ROS 1 latched topics and queue-size assumptions were re-evaluated as ROS 2 QoS.
- [ ] Long-running services were reviewed for action migration.
- [ ] Interface packages use `rosidl_generate_interfaces` and are split out when needed.
- [ ] Launch files were migrated with ROS 2 scoping and namespacing rules in mind.
- [ ] Bridge usage, if any, is explicit and temporary.

## Good References

- ROS 2 Humble migration guides for packages, interfaces, launch, and parameters
- ROS 2 Humble C++ and Python migration examples
- ROS 2 Humble docs for QoS, callback groups, node arguments, and topics vs services vs actions
- ROS 2 design docs for launch architecture and major ROS 1 to ROS 2 changes