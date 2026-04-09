## What Is Real-Time with ROS 2?

Real-time robotics is about deterministic timing, not just high average speed.

- Hard real-time: deadlines are strict and a miss can cause unsafe behavior (for example, unstable motor control).
- Soft real-time: occasional misses are acceptable, but performance degrades (for example, perception frame drops).

ROS 2 is a strong middleware layer, but the default executor path is not real-time safe for hard control loops:

- It can allocate memory at runtime.
- It uses standard synchronization primitives such as `std::mutex`.
- It runs under normal Linux scheduling behavior, where wakeup latency is not strictly bounded.

Latency in Linux robotics stacks typically accumulates from three sources:

1. Application latency (your code path and data structures)
2. OS scheduler latency (thread wakeup and run-queue delays)
3. Hardware latency (SMI, dynamic frequency changes, platform firmware activity)

```text
[Hardware Latency] -> [OS Scheduler Latency] -> [Application Latency] -> Response
```

| Property | Hard RT | Soft RT | ROS 2 Default |
|---|---|---|---|
| Max latency | <=1-5 ms | 10-100 ms | Unbounded |
| Deadline miss consequence | Safety-critical failure | Degraded perf | Lag/jitter |
| Suitable for | PID/motor control | Planning, vision | Pub/sub, services |
| Kernel required | PREEMPT_RT | Stock | Stock |

> **Note:** A common architecture is to keep ROS 2 for orchestration and messaging while running the inner control loop in a dedicated PREEMPT_RT thread.

## How to Get Started

### 1. Check your kernel

```bash
uname -a
cat /sys/kernel/realtime || true
```

Expected signs:

- `uname -a` contains `PREEMPT_RT` for an RT kernel.
- `/sys/kernel/realtime` prints `1` on kernels exposing that interface.

### 2. Install PREEMPT_RT kernel

Ubuntu/Debian RT variants:

```bash
sudo apt update
sudo apt install linux-image-rt-$(dpkg --print-architecture)
sudo reboot
```

Compile-from-source option (when distro package is unavailable):

- Kernel source and PREEMPT_RT patchset: https://www.kernel.org

> **Warning:** RT kernel package names vary by distro flavor. Verify availability with `apt search linux-image-rt` before installing.

### 3. Configure system

Four-step baseline checklist:

1. Disable SMT (hyper-threading) in BIOS/UEFI.
2. Disable dynamic frequency scaling (set performance governor).
3. Disable RT throttling.
4. Check for rogue RT processes.

Commands:

```bash
# 1) Inspect SMT status (disable in BIOS/UEFI for strict RT work)
cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo "SMT status file not present"

# 2) Force performance governor
sudo apt install linux-tools-common linux-tools-$(uname -r) cpufrequtils -y
sudo cpupower frequency-set -g performance

# 3) Disable RT throttling
echo -1 | sudo tee /proc/sys/kernel/sched_rt_runtime_us

# 4) Inspect RT-priority tasks
ps -eo pid,rtprio,cls,cmd | awk '$2 != "-" {print}'
```

Persist RT throttling setting:

```bash
echo 'kernel.sched_rt_runtime_us = -1' | sudo tee /etc/sysctl.d/99-rt.conf
sudo sysctl --system
```

### 4. Validate with cyclictest

```bash
sudo apt install rt-tests stress-ng -y
sudo stress-ng -c "$(nproc)" --timeout 60s &
cyclictest --mlockall --smp --priority=80 --interval=200 --distance=0 -D 60s
```

Interpretation guide:

- Focus on worst-case (`Max`) latency, not average.
- PREEMPT_RT systems should typically stay well below 200 us under load.
- If max spikes, inspect scheduler events with `trace-cmd` (see section 6).

### 5. Set RT permissions

Add limits for your user or RT group in `/etc/security/limits.conf`:

```conf
@realtime   soft  rtprio   98
@realtime   hard  rtprio   98
@realtime   soft  memlock  unlimited
@realtime   hard  memlock  unlimited
@realtime   soft  nice     -20
@realtime   hard  nice     -20
```

Then add your user to the group and re-login:

```bash
sudo groupadd -f realtime
sudo usermod -aG realtime "$USER"
```

> **Tip:** `rtprio=80` is a practical default for application control loops: high enough to preempt normal work, low enough to avoid starving critical kernel tasks.

## Dependencies

| Dependency | Purpose | How to Install |
|---|---|---|
| PREEMPT_RT kernel | Bounded scheduler latency for RT threads | `sudo apt install linux-image-rt-$(dpkg --print-architecture)` (or compile from kernel.org) |
| build-essential, cmake | C++ toolchain and build generator | `sudo apt install build-essential cmake` |
| libprotobuf-dev, protobuf-compiler | cactus-rt tracing/Perfetto protobuf output | `sudo apt install libprotobuf-dev protobuf-compiler` |
| libgtest-dev | Unit tests | `sudo apt install libgtest-dev` |
| libbenchmark-dev | Microbenchmarks and latency benchmarks | `sudo apt install libbenchmark-dev` |
| cactus-rt | RT framework classes and utilities | Add with CMake `FetchContent` |
| ROS 2 Humble | ROS graph, transport, and tooling | `sudo apt install ros-humble-desktop` or `sudo apt install ros-humble-ros-base` |
| colcon | ROS 2 workspace build tool | `sudo apt install python3-colcon-common-extensions` |

Required Ubuntu/Debian packages from cactus-rt docs:

```bash
sudo apt install build-essential cmake protobuf-compiler libprotobuf-dev libgtest-dev libbenchmark-dev
```

CMake integration:

```cmake
include(FetchContent)
FetchContent_Declare(
  cactus_rt
  GIT_REPOSITORY https://github.com/SasaKuruppuarachchi/agipix-rt.git
  GIT_TAG        main  # pin to a specific release tag in production
)
FetchContent_MakeAvailable(cactus_rt)

target_link_libraries(my_target PRIVATE cactus_rt)
```

> **Note:** Pin `GIT_TAG` to a release tag in production for reproducibility and deterministic CI behavior.

## Architecture

```text
┌─────────────────────────────────────────────────────┐
│                   Your ROS 2 Node                   │
│  (rclcpp Node, launches App, owns ROS subscribers) │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│              cactus_rt::App                         │
│  ┌──────────────────────────────────────────────┐  │
│  │  mlockall()  |  heap config  |  signal setup │  │
│  └──────────────────────────────────────────────┘  │
│  ┌────────────────┐  ┌────────────────────────────┐ │
│  │ CyclicThread   │  │   Non-RT Service Thread    │ │
│  │ (SCHED_FIFO)   │  │   (logging, ROS executor)  │ │
│  │ rtprio=80      │  │   (SCHED_OTHER)            │ │
│  │ Loop() @ NHz   │  │                            │ │
│  └──────┬─────────┘  └────────────────────────────┘ │
│         │ RT-safe data exchange                      │
│         │ (lockless queue / PI mutex)                │
└─────────┼───────────────────────────────────────────┘
          ▼
┌──────────────────────────────────────┐
│  Hardware / Robot API (PWM, CAN, I2C)│
└──────────────────────────────────────┘
```

Why the ROS executor runs in non-RT:

- `rclcpp::spin()` is not designed as a hard RT loop and may allocate memory.
- ROS callbacks can trigger variable-duration work and lock contention.
- Running executor work as `SCHED_OTHER` prevents it from stealing deterministic RT budget.

How data crosses RT and non-RT boundary safely:

- Preferred for high-rate streams: lockless SPSC queue (`moodycamel::ReaderWriterQueue`).
- For shared state: PI mutex (`cactus_rt::mutex`) with very short critical sections.

Why `cactus_rt::mutex` instead of `std::mutex`:

- `std::mutex` does not guarantee priority inheritance on RT Linux paths.
- `cactus_rt::mutex` is configured with `PTHREAD_PRIO_INHERIT` to reduce priority inversion risk.

Thread priority hierarchy:

| Thread type | Scheduler | Priority | Example |
|---|---|---|---|
| Critical kernel tasks | SCHED_FIFO | 99 | Watchdog, migration |
| Hardware IRQ handlers | SCHED_FIFO | 50 | Device interrupts |
| **Your RT loop** | **SCHED_FIFO** | **80** | **CyclicThread** |
| ROS 2 executor | SCHED_OTHER | nice 0 | rclcpp::spin |
| Logger thread | SCHED_OTHER | nice 5 | Quill backend |

> **Warning:** Keep user RT threads below 99. Priority 99 can starve critical kernel housekeeping.

## Robotics-Focused Tutorials

### Tutorial 1: 1000 Hz Motor Control Loop

`CMakeLists.txt` snippet:

```cmake
cmake_minimum_required(VERSION 3.16)
project(rt_motor_loop LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(rclcpp REQUIRED)

include(FetchContent)
FetchContent_Declare(
  cactus_rt
  GIT_REPOSITORY https://github.com/SasaKuruppuarachchi/agipix-rt.git
  GIT_TAG main
)
FetchContent_MakeAvailable(cactus_rt)

add_executable(rt_motor src/rt_motor.cpp)
target_link_libraries(rt_motor PRIVATE cactus_rt)
ament_target_dependencies(rt_motor rclcpp)
```

`src/rt_motor.cpp`:

```cpp
#include <cstdint>
#include <memory>

#include <rclcpp/rclcpp.hpp>

#include <cactus_rt/app.h>
#include <cactus_rt/cyclic_thread.h>

struct Velocity2D {
  double vx{0.0};
  double vy{0.0};
  double w{0.0};
};

struct StampedVelocity2D {
  Velocity2D value;
};

class MotorApi {
 public:
  void SetVelocity(double vx, double vy, double w) noexcept {
    (void)vx;
    (void)vy;
    (void)w;
  }
};

class RtMotorLoop final : public cactus_rt::CyclicThread {
 public:
  static cactus_rt::CyclicThreadConfig MakeConfig() {
    cactus_rt::CyclicThreadConfig cfg;
    cfg.name = "rt_motor_1khz";
    cfg.period_ns = 1'000'000;  // 1000 Hz
    cfg.scheduler = SCHED_FIFO;
    cfg.priority = 80;
    return cfg;
  }

  explicit RtMotorLoop(MotorApi* motor)
      : cactus_rt::CyclicThread(MakeConfig()), motor_(motor) {}

  cactus_rt::LoopControl Loop(int64_t elapsed_ns) noexcept final {
    (void)elapsed_ns;
    // Replace with cactus-rt ROS 2 lockless passthrough subscriber in production.
    const StampedVelocity2D cmd = ReadLatestCmd();
    motor_->SetVelocity(cmd.value.vx, cmd.value.vy, cmd.value.w);
    return cactus_rt::LoopControl::Continue;
  }

 private:
  StampedVelocity2D ReadLatestCmd() const noexcept { return {}; }

  MotorApi* motor_;
};

int main(int argc, char** argv) {
  rclcpp::init(argc, argv);

  cactus_rt::App app{"rt_motor_app"};
  MotorApi motor;

  auto rt_loop = std::make_shared<RtMotorLoop>(&motor);
  app.RegisterThread(rt_loop);
  app.Start();

  rclcpp::shutdown();
  return 0;
}
```

> **Tip:** Keep ROS 2 subscription callbacks and message conversion out of `Loop()`; pass only compact, pre-validated control targets into the RT thread.

### Tutorial 2: RT Thread with Non-RT Data Logger (PI Mutex)

`CMakeLists.txt` snippet:

```cmake
cmake_minimum_required(VERSION 3.16)
project(rt_logger_bridge LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
FetchContent_Declare(
  cactus_rt
  GIT_REPOSITORY https://github.com/SasaKuruppuarachchi/agipix-rt.git
  GIT_TAG main
)
FetchContent_MakeAvailable(cactus_rt)

add_executable(rt_logger src/rt_logger.cpp)
target_link_libraries(rt_logger PRIVATE cactus_rt)
```

`src/rt_logger.cpp`:

```cpp
#include <atomic>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <memory>
#include <thread>

#include <cactus_rt/app.h>
#include <cactus_rt/cyclic_thread.h>
#include <cactus_rt/mutex.h>

struct SharedMetrics {
  cactus_rt::mutex mtx;
  double position{0.0};
  double velocity{0.0};
  uint64_t seq{0};
};

class SensorLoop final : public cactus_rt::CyclicThread {
 public:
  static cactus_rt::CyclicThreadConfig MakeConfig() {
    cactus_rt::CyclicThreadConfig cfg;
    cfg.name = "sensor_rt";
    cfg.period_ns = 1'000'000;  // 1000 Hz
    cfg.scheduler = SCHED_FIFO;
    cfg.priority = 80;
    return cfg;
  }

  explicit SensorLoop(SharedMetrics* shared)
      : cactus_rt::CyclicThread(MakeConfig()), shared_(shared) {}

  cactus_rt::LoopControl Loop(int64_t elapsed_ns) noexcept final {
    (void)elapsed_ns;
    const double pos = FakeReadPosition();
    const double vel = FakeReadVelocity();

    {
      std::scoped_lock<cactus_rt::mutex> lock(shared_->mtx);
      shared_->position = pos;
      shared_->velocity = vel;
      ++shared_->seq;
    }

    return cactus_rt::LoopControl::Continue;
  }

 private:
  static double FakeReadPosition() noexcept { return 1.0; }
  static double FakeReadVelocity() noexcept { return 0.1; }

  SharedMetrics* shared_;
};

int main() {
  cactus_rt::App app{"rt_logger_app"};

  SharedMetrics shared;
  std::atomic<bool> running{true};

  auto rt_loop = std::make_shared<SensorLoop>(&shared);
  app.RegisterThread(rt_loop);

  std::thread non_rt_logger([&]() {
    std::ofstream out("metrics.csv");
    out << "seq,position,velocity\n";
    while (running.load(std::memory_order_relaxed)) {
      uint64_t seq;
      double p;
      double v;
      {
        std::scoped_lock<cactus_rt::mutex> lock(shared.mtx);
        seq = shared.seq;
        p = shared.position;
        v = shared.velocity;
      }
      out << seq << ',' << p << ',' << v << '\n';
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  });

  app.Start();
  std::this_thread::sleep_for(std::chrono::seconds(3));
  running.store(false, std::memory_order_relaxed);
  non_rt_logger.join();
  return 0;
}
```

> **Warning:** Code inside a PI mutex critical section must also be RT-safe. Keep lock hold times tiny and avoid allocation, I/O, and blocking calls while locked.

### Tutorial 3: Perfetto Tracing for Latency Visualization

`CMakeLists.txt` snippet:

```cmake
cmake_minimum_required(VERSION 3.16)
project(rt_perfetto_trace LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
FetchContent_Declare(
  cactus_rt
  GIT_REPOSITORY https://github.com/SasaKuruppuarachchi/agipix-rt.git
  GIT_TAG main
)
FetchContent_MakeAvailable(cactus_rt)

add_executable(rt_trace src/rt_trace.cpp)
target_link_libraries(rt_trace PRIVATE cactus_rt)
```

`src/rt_trace.cpp`:

```cpp
#include <cstdint>
#include <memory>

#include <cactus_rt/app.h>
#include <cactus_rt/cyclic_thread.h>
#include <cactus_rt/tracing.h>

class TracedLoop final : public cactus_rt::CyclicThread {
 public:
  static cactus_rt::CyclicThreadConfig MakeConfig() {
    cactus_rt::CyclicThreadConfig cfg;
    cfg.name = "traced_loop";
    cfg.period_ns = 2'000'000;  // 500 Hz
    cfg.scheduler = SCHED_FIFO;
    cfg.priority = 80;
    return cfg;
  }

  TracedLoop() : cactus_rt::CyclicThread(MakeConfig()) {}

  cactus_rt::LoopControl Loop(int64_t elapsed_ns) noexcept final {
    auto span = Tracer().WithSpan("ControlStep");
    (void)elapsed_ns;
    ControlComputation();
    return cactus_rt::LoopControl::Continue;
  }

 private:
  static void ControlComputation() noexcept {
    volatile int x = 0;
    for (int i = 0; i < 200; ++i) {
      x += i;
    }
    (void)x;
  }
};

int main() {
  cactus_rt::App app{"rt_trace_app"};
  auto loop = std::make_shared<TracedLoop>();
  app.RegisterThread(loop);
  app.Start();

  // Dump trace file path and API name can vary by release.
  // Use your build's configured cactus-rt trace dump helper to write a perfetto protobuf.
  return 0;
}
```

Collect and open trace data:

```bash
# Example workflow; exact executable/flag names can vary by integration.
./rt_trace
ls -lh *.pftrace *.perfetto-trace *.pb 2>/dev/null
```

Open the output in Perfetto UI:

1. Go to https://ui.perfetto.dev
2. Click Open trace file and select your trace artifact.
3. Inspect `ControlStep` span durations and gaps.

## Visualization Methods

### 1. Perfetto trace viewer (https://ui.perfetto.dev)

How cactus-rt emits traces:

- Instrumented spans in RT loops are captured with lock-free tracing hooks.
- Trace data is flushed asynchronously to a Perfetto-compatible protobuf file.

How to collect trace file:

```bash
# Run your instrumented binary and collect its trace output artifact.
./your_rt_binary
find . -maxdepth 2 -type f \( -name "*.pftrace" -o -name "*.perfetto-trace" -o -name "*.pb" \)
```

What to look for:

- Span duration outliers (execution spikes)
- Inter-iteration gaps larger than expected period (wakeup jitter)
- Boundary latency between RT loop and non-RT services

### 2. cyclictest histogram

```bash
cyclictest --mlockall --smp --priority=80 --interval=200 --distance=0 -D 60s -h 400 > latency_hist.txt
```

Histogram interpretation:

- Each bucket is a latency bin (in us) with occurrence counts.
- The tail is more important than the center; long tails indicate sporadic deadline risk.

Quick min/avg/max extraction:

```bash
grep -E "Min|Avg|Max" latency_hist.txt
```

Optional quick plot with gnuplot:

```bash
gnuplot -persist <<'EOF'
set title "cyclictest latency histogram"
set xlabel "Latency bucket (us)"
set ylabel "Count"
plot "latency_hist.txt" using 1:2 with impulses title "latency"
EOF
```

### 3. trace-cmd + kernel-shark

Start tracing:

```bash
sudo apt install trace-cmd kernelshark -y
sudo trace-cmd start -p wakeup_rt
# Run workload for ~30-60s in another shell
sudo trace-cmd stop
sudo trace-cmd extract -o wakeup_rt.dat
```

Visualize scheduling behavior:

```bash
kernelshark wakeup_rt.dat
```

What `wakeup_rt` shows:

- Which task woke your RT thread
- When wakeup happened versus when the thread actually ran
- Preemption chains and blocking interference causing jitter

> **Tip:** Use Perfetto for application-level spans and `trace-cmd`/KernelShark for kernel scheduling root-cause analysis.

## Jetson Orin NX Super + ConnectTech NGX027

This section covers getting PREEMPT_RT and cactus-rt running on the **NVIDIA Jetson Orin NX Super** mounted on the **ConnectTech Super Hadron-DM (NGX027)** carrier. The BSP used is the official ConnectTech RT release **ORIN-NX-NANO-RT-36.4.4 V005**, which includes PREEMPT_RT kernel patches applied on top of L4T 36.4.4 (JetPack 6.2.1, Ubuntu 22.04).

> **Note:** PREEMPT_RT support for the NGX027 was introduced in BSP version V005 (December 2025). Earlier V001–V004 releases do NOT include RT patches. Always verify your installed version with `cat /etc/cti/CTI-L4T.version`.

### Hardware Reference

| Item | Details |
|---|---|
| Carrier board | ConnectTech Super Hadron-DM (NGX027) |
| Jetson module | Jetson Orin NX Super |
| BSP | ORIN-NX-NANO-RT-36.4.4 V005 |
| L4T version | R36.4.4 (JetPack 6.2.1) |
| Host OS | Ubuntu 20.04 or 22.04 (host), Ubuntu 22.04 (target) |
| Boot media | NVMe M.2 (required — Orin NX has no eMMC) |
| USB for flashing | USB-C or micro-USB to host, per NGX027 manual |

NGX027 interfaces relevant to robotics:

| Interface | Details |
|---|---|
| CAN | Supported |
| GbE | 1× Gigabit Ethernet |
| UART | Supported |
| SPI | Supported |
| I2C | Supported |
| GPIO | Supported |
| PWM | Supported |
| USB 3.0 | Supported |
| NVMe M.2 | Required for rootfs |
| Wi-Fi/Bluetooth | M.2 E-Key slot |
| MIPI CSI2 | 2× 22-pin connectors (uses NGX024 Hadron Dual Mipi software config) |
| Power input | +10 V to +60 V DC (wide-input) |

---

### Step 1: Install JetPack 6.2.1 on the Host

You need an **x86/x64 Ubuntu 20.04 or 22.04** host machine.

**Option A — NVIDIA SDK Manager (recommended):**

```bash
# Install SDK Manager from https://developer.nvidia.com/sdk-manager
# Launch it, select:
#   Product: Jetson
#   Hardware: Jetson Orin NX
#   OS: JetPack 6.2.1 (L4T 36.4.4)
#   Components: ONLY "Jetson Linux" — UNCHECK SDK Components
#   Action: "Download now, Install later"
sdkmanager
```

**Option B — Manual download:**

```bash
export BSP_ROOT=~/jetson-flash
mkdir -p "$BSP_ROOT" && cd "$BSP_ROOT"

# Download from https://developer.nvidia.com/embedded/jetson-linux-r3644
# Place both files into $BSP_ROOT then:
sudo tar -jxf Jetson_Linux_R36.4.4_aarch64.tbz2
sudo tar -C Linux_for_Tegra/rootfs/ -xjf \
  Tegra_Linux_Sample-Root-Filesystem_R36.4.4_aarch64.tbz2
```

---

### Step 2: Apply the ConnectTech RT BSP

Download the ConnectTech RT BSP and install it on top of the L4T tree:

```bash
cd "$BSP_ROOT/Linux_for_Tegra"

# Download the RT-specific BSP (V005 includes PREEMPT_RT patches)
# Check https://connecttech.com/resource-center/l4t-board-support-packages/ for latest
wget https://connecttech.com/ftp/Drivers/CTI-L4T-ORIN-NX-NANO-36.4.4-V005.tgz

# Extract
sudo tar -xzf CTI-L4T-ORIN-NX-NANO-36.4.4-V005.tgz

# Run the install script
cd CTI-L4T
sudo ./install.sh
cd ..
```

> **Warning:** Upgrading L4T or CTI-BSP versions without reflashing is not supported. If you need a different version, you must reflash from scratch.

Verify BSP installation:

```bash
cat /etc/cti/CTI-L4T.version
# Expected output: ORIN-NX-NANO-RT-36.4.4 V005
```

---

### Step 3: Put the Jetson into Recovery Mode

1. Connect an NVMe M.2 card to the NGX027 M.2 slot (required — Orin NX has no eMMC boot).
2. Connect the NGX027 to the host via USB (see NGX027 manual for the correct port).
3. Enter forced recovery mode:
   - Hold the **Force Recovery** button.
   - Press and release the **Power** button.
   - Release **Force Recovery**.
4. Verify on the host:

```bash
lsusb | grep "0955:"
# Must show Nvidia Corp. APX or similar
```

---

### Step 4: Flash with the NGX027 Config

The NGX027 uses the **Hadron Dual Mipi (NGX024) software configuration**.

**Option A — Interactive helper script:**

```bash
cd "$BSP_ROOT/Linux_for_Tegra"
sudo ./cti-flash.sh
# Follow the menu: select Orin NX → Hadron (NGX027/NGX024 config)
```

**Option B — Manual flash:**

```bash
cd "$BSP_ROOT/Linux_for_Tegra"

# Standard mode
sudo ./cti-nvme-flash.sh cti/orin-nx/hadron/base

# OR Super Mode (for Orin NX Super — use this for the NX Super module)
SUPER_MODE=1 sudo ./cti-nvme-flash.sh cti/orin-nx/hadron/base
```

> **Note:** The `hadron` config path covers both NGX024 and NGX027 (Super Hadron-DM). NGX027 uses NGX024 software configuration as stated in the BSP release notes.

Once flashing completes the Jetson will reboot automatically.

---

### Step 5: Enable the PREEMPT_RT Kernel

After booting the freshly flashed system, add the NVIDIA RT kernel repository and install the RT kernel:

```bash
# On the Jetson (via SSH or direct terminal)

# Add NVIDIA RT kernel apt source
sudo sh -c 'echo "deb https://repo.download.nvidia.com/jetson/rt-kernel r36.4 main" \
  > /etc/apt/sources.list.d/nvidia-l4t-rt-apt-source.list'

sudo apt update

# Install the PREEMPT_RT kernel and matching modules
sudo apt install \
  nvidia-l4t-rt-kernel \
  nvidia-l4t-rt-kernel-headers \
  nvidia-l4t-rt-kernel-oot-modules \
  nvidia-l4t-display-rt-kernel
```

Switch the default boot entry to the RT kernel:

```bash
sudo nano /boot/extlinux/extlinux.conf
```

Change the `DEFAULT` line to select the RT kernel:

```conf
TIMEOUT 30
DEFAULT real-time
```

Reboot and verify:

```bash
sudo reboot

# After reboot:
uname -a
# Expected: ... 5.15.xxx-rt... PREEMPT_RT ...
cat /sys/kernel/realtime
# Expected: 1
```

---

### Step 6: Configure the System for RT

Apply the standard RT tuning on the Jetson. The Jetson Orin NX is an ARM64 (aarch64) SoC — the same Linux RT tuning principles apply.

```bash
# Disable RT throttling
echo -1 | sudo tee /proc/sys/kernel/sched_rt_runtime_us

# Persist across reboots
echo 'kernel.sched_rt_runtime_us = -1' | sudo tee /etc/sysctl.d/99-rt.conf
sudo sysctl --system

# Set performance CPU frequency governor (Jetson-specific tool)
sudo nvpmodel -m 0           # Maximum performance power mode
sudo jetson_clocks           # Lock clocks to max frequency (disables freq scaling)
```

> **Tip:** `jetson_clocks` both disables dynamic frequency scaling AND pins the GPU/CPU/memory clocks. This is the equivalent of setting the `performance` CPU governor on x86. Run it once per boot or add it to a systemd service.

Set RT permissions for your user:

```bash
sudo groupadd -f realtime
sudo usermod -aG realtime "$USER"
```

Add to `/etc/security/limits.d/99-realtime.conf`:

```conf
@realtime   soft  rtprio   98
@realtime   hard  rtprio   98
@realtime   soft  memlock  unlimited
@realtime   hard  memlock  unlimited
```

Log out and back in (or reboot) for group membership to take effect.

---

### Step 7: Validate RT Latency

```bash
sudo apt install rt-tests stress-ng -y

# Run cyclictest under CPU stress
stress-ng -c "$(nproc)" --timeout 60s &
cyclictest --mlockall --smp --priority=80 --interval=200 --distance=0 -D 60s
```

Expected results on Jetson Orin NX Super with PREEMPT_RT:

| Condition | Typical max latency |
|---|---|
| Idle | < 50 μs |
| Under `stress-ng -c $(nproc)` load | < 300 μs |
| With `jetson_clocks` enabled | Noticeably better tail latency |

> **Warning:** If max latency exceeds 500 μs consistently, check for rogue RT processes (`ps -eo pid,rtprio,cls,cmd | awk '$2 != "-" {print}'`) and verify `jetson_clocks` is active (`sudo jetson_clocks --show`).

---

### Step 8: Build and Run cactus-rt on the Jetson

Install build dependencies on the Jetson:

```bash
sudo apt install build-essential cmake \
  protobuf-compiler libprotobuf-dev \
  libgtest-dev libbenchmark-dev -y
```

Build your cactus-rt project (cross-compilation or native on Jetson):

```bash
# Native build on Jetson (slower but simpler)
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j"$(nproc)"

# Run as root (or with realtime group permissions)
sudo ./your_rt_binary
```

> **Note:** cactus-rt's `CyclicThread` sets SCHED_FIFO + rtprio=80. On Jetson, this requires running as root or having the memlock/rtprio limits configured in Step 6.

---

### Step 9: Switch Back to Standard Kernel (Optional)

To switch back to the stock L4T kernel for development:

```bash
sudo nano /boot/extlinux/extlinux.conf
# Change DEFAULT back to: DEFAULT primary
sudo reboot
```

---

### Jetson-Specific Known Issues (BSP V005)

| Issue | Details | Workaround |
|---|---|---|
| UEFI runtime services | May introduce latency spikes on first boot | Disable in UEFI/firmware settings if sub-100 μs tail latency is needed |
| No eMMC on Orin NX | Rootfs must be on NVMe | Always connect NVMe before flashing |
| Suspend/wake system error | Suspend causes boot error | Do not enable suspend on this BSP |
| SD card not supported | Orin NX/Nano does not support SD card pin mapping from Xavier NX carriers | Use NVMe only |
| Display RT modules require `IGNORE_PREEMPT_RT_PRESENCE=1` | Build-time only | Export the variable before building out-of-tree display modules |
| USB OTG hotplug | Polaris (NGX015) OTG USB does not re-detect after disconnect | Not applicable to NGX027 |

---

### Quick Reference: NGX027 RT Setup Checklist

- [ ] Host: Ubuntu 20.04 or 22.04, x86/x64
- [ ] BSP: `ORIN-NX-NANO-RT-36.4.4 V005` (confirmed with `cat /etc/cti/CTI-L4T.version`)
- [ ] NVMe M.2 connected before flashing
- [ ] Flashed with `SUPER_MODE=1 ./cti-nvme-flash.sh cti/orin-nx/hadron/base`
- [ ] RT kernel installed: `nvidia-l4t-rt-kernel` + matching modules
- [ ] `extlinux.conf` DEFAULT set to `real-time`
- [ ] `uname -a` shows `PREEMPT_RT`; `/sys/kernel/realtime` prints `1`
- [ ] `sudo nvpmodel -m 0 && sudo jetson_clocks` run on each boot
- [ ] RT throttling disabled: `/proc/sys/kernel/sched_rt_runtime_us = -1`
- [ ] `realtime` group configured with rtprio=98 and unlimited memlock
- [ ] `cyclictest` max latency validated under `stress-ng` load

### References

- ConnectTech BSP release notes: ORIN-NX-NANO-RT-36.4.4 (V005, December 2025)
- ConnectTech L4T BSP resource center: https://connecttech.com/resource-center/l4t-board-support-packages/
- ConnectTech KDB373 (SDK Manager installation): https://connecttech.com/resource-center/kdb373/
- NVIDIA Jetson Linux R36.4.4: https://developer.nvidia.com/embedded/jetson-linux-r3644
- NVIDIA L4T PREEMPT_RT kernel guide: https://docs.nvidia.com/jetson/archives/r36.4/DeveloperGuide/SD/Kernel/KernelCustomization.html
- ConnectTech Super Hadron-DM (NGX027): https://connecttech.com/product/super-hadron-dm-carrier-for-nvidia-jetson-orin-nx/