---
name: cactus-rt
description: Practical rules for building real-time Linux applications with cactus-rt, targeting PREEMPT_RT kernels and ROS 2 robotics integration.
license: "See repository LICENSE"
user-invocable: false
---

# Cactus-rt Real-Time Linux

Use this skill when the user explicitly says "use cactus-rt" or when building RT C++ applications with the cactus-rt framework.

## Priorities

Apply these in order:

1. **Bounded Latency First**: Every line of RT code must have a known worst-case execution time.
2. **Memory Safety Before Loop**: Call mlockall() and pre-allocate all RT memory before entering Loop().
3. **Correct Scheduling**: SCHED_FIFO at rtprio=80, never inherit parent's scheduler.
4. **Priority-Safe Synchronization**: PI mutex or lockless data structures; never std::mutex in RT paths.
5. **Monotonic Time Only**: Use CLOCK_MONOTONIC for all timing; never CLOCK_REALTIME.
6. **RT/Non-RT Boundary Discipline**: ROS 2 spin, logging, and disk I/O are always non-RT.
7. **Observe Before Optimizing**: Measure with Perfetto traces and cyclictest before tuning.

## Core Rules

1. **Use cactus_rt::App as the top-level owner**
   - Always construct `cactus_rt::App` before starting any thread.
   - App calls `mlockall(MCL_CURRENT | MCL_FUTURE)` automatically.
   - App configures `malloc` to disable memory trimming (disables `free` returning pages to OS).
   - Register threads with App before calling `app.Start()`.

```cpp
#include <memory>

#include <cactus_rt/app.h>
#include <cactus_rt/cyclic_thread.h>

class MyLoop final : public cactus_rt::CyclicThread {
 public:
  static cactus_rt::CyclicThreadConfig MakeConfig();
  MyLoop() : cactus_rt::CyclicThread(MakeConfig()) {}
  cactus_rt::LoopControl Loop(int64_t elapsed_ns) noexcept final;
};

int main() {
  cactus_rt::App app{"my_rt_app"};
  auto loop = std::make_shared<MyLoop>();
  app.RegisterThread(loop);
  app.Start();
  return 0;
}
```

2. **Inherit CyclicThread and implement Loop() noexcept**
   - Override `Loop(int64_t elapsed_ns) noexcept` because exceptions are not RT-safe.
   - Return `LoopControl::Continue` to keep running, `LoopControl::Stop` to exit.
   - Provide `MakeConfig()` with period in ns, scheduler policy, and rtprio.
   - Never call blocking APIs, dynamic allocators, or std::mutex inside Loop().

```cpp
class ControlLoop final : public cactus_rt::CyclicThread {
 public:
  static cactus_rt::CyclicThreadConfig MakeConfig() {
    cactus_rt::CyclicThreadConfig cfg;
    cfg.name = "control_loop";
    cfg.period_ns = 1'000'000;
    cfg.scheduler = SCHED_FIFO;
    cfg.priority = 80;
    return cfg;
  }

  ControlLoop() : cactus_rt::CyclicThread(MakeConfig()) {}

  cactus_rt::LoopControl Loop(int64_t elapsed_ns) noexcept final {
    (void)elapsed_ns;
    return cactus_rt::LoopControl::Continue;
  }
};
```

3. **Set SCHED_FIFO + rtprio=80, never 99**
   - rtprio=99 blocks critical kernel tasks (watchdog, task migration).
   - rtprio=80 is above hardware IRQ handlers (50) and correctly preemptible by the kernel.
   - Set `PTHREAD_EXPLICIT_SCHED` so thread inherits from attribute, not parent.
   - Run as root or add rtprio limit in `/etc/security/limits.conf`.

```cpp
cactus_rt::CyclicThreadConfig cfg;
cfg.name = "rt_loop";
cfg.period_ns = 1'000'000;
cfg.scheduler = SCHED_FIFO;
cfg.priority = 80;
cfg.inherit_scheduler = PTHREAD_EXPLICIT_SCHED;
```

4. **Replace std::mutex with cactus_rt::mutex everywhere in RT paths**
   - `std::mutex` uses `PTHREAD_PRIO_NONE` with no guaranteed priority inheritance.
   - `cactus_rt::mutex` uses `PTHREAD_PRIO_INHERIT`.
   - Code in a PI mutex critical section must itself be RT-safe.
   - Use `std::scoped_lock<cactus_rt::mutex>` for RAII.

```cpp
#include <cactus_rt/mutex.h>

struct SharedState {
  cactus_rt::mutex mtx;
  double value{0.0};
};

void WriteShared(SharedState& s, double v) noexcept {
  std::scoped_lock<cactus_rt::mutex> lock(s.mtx);
  s.value = v;
}
```

5. **Use lockless structures for high-frequency inter-thread data**
   - `moodycamel::ReaderWriterQueue` is SPSC and allocation-free after construction.
   - Use it for RT-to-non-RT metrics pipelines.
   - For ROS 2 topic-to-RT-thread, use cactus-rt `ReadLatest()` lockless handoff.
   - Never use allocator-heavy queues in RT paths.

```cpp
#include <readerwriterqueue.h>

moodycamel::ReaderWriterQueue<int> q(1024);

// RT producer
void PushMetric(int v) noexcept {
  (void)q.try_enqueue(v);
}

// Non-RT consumer
void Drain() {
  int v;
  while (q.try_dequeue(v)) {
    // log/process
  }
}
```

6. **Use CLOCK_MONOTONIC exclusively; never CLOCK_REALTIME**
   - `CLOCK_REALTIME` can jump due to NTP/leap updates and breaks deterministic sleep math.
   - `CLOCK_MONOTONIC` is strictly increasing and safe for period arithmetic.
   - CyclicThread uses `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, ...)` internally.
   - For duration measurements, use `clock_gettime(CLOCK_MONOTONIC, ...)`.

```cpp
timespec next_wakeup{};
clock_gettime(CLOCK_MONOTONIC, &next_wakeup);

// work...

next_wakeup.tv_nsec += 1'000'000;
while (next_wakeup.tv_nsec >= 1'000'000'000) {
  next_wakeup.tv_nsec -= 1'000'000'000;
  next_wakeup.tv_sec += 1;
}
clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next_wakeup, nullptr);
```

7. **Keep ROS 2 spin in a dedicated non-RT thread**
   - `rclcpp::spin()` performs dynamic work and is not for hard RT paths.
   - Run spin in `SCHED_OTHER` while CyclicThread runs in `SCHED_FIFO`.
   - Use cactus-rt ROS passthrough for RT-safe boundary transfer.
   - RT loop reads command with `ReadLatest()` and publishes via safe passthrough API.

```cpp
std::thread ros_executor_thread([node]() {
  rclcpp::spin(node);
});

// Separate from app.Start() launching RT CyclicThread(s)
```

8. **Validate system latency with cyclictest before shipping**
   - Run `cyclictest --mlockall --smp --priority=80 --interval=200 --distance=0 -D 60s` under load.
   - Typical acceptance: <=200 us worst-case on PREEMPT_RT, <=1 ms on stock kernel.
   - If exceeded, inspect scheduling with `trace-cmd start -p wakeup_rt`.
   - Check for rogue RT processes that steal scheduling budget.

```bash
stress-ng -c "$(nproc)" --timeout 60s &
cyclictest --mlockall --smp --priority=80 --interval=200 --distance=0 -D 60s
ps -eo pid,rtprio,cmd | grep -v ' - '
sudo trace-cmd start -p wakeup_rt
```

9. **Instrument RT loops with cactus-rt tracing**
   - Use RAII spans: `auto span = Tracer().WithSpan("LoopSection")`.
   - Trace flush is asynchronous and Perfetto-compatible.
   - Analyze in https://ui.perfetto.dev.
   - Look for span spikes, loop gaps, and cross-thread latency.

```cpp
cactus_rt::LoopControl Loop(int64_t elapsed_ns) noexcept final {
  auto span = Tracer().WithSpan("LoopSection");
  (void)elapsed_ns;
  RunControlStep();
  return cactus_rt::LoopControl::Continue;
}
```

## Review Heuristics

- `std::mutex` used anywhere in an RT path
- `rclcpp::spin` or `rclcpp::spin_some` called inside `Loop()`
- Dynamic allocation (`new`, `std::vector::push_back` without reserve, `std::string` construction) inside `Loop()`
- `CLOCK_REALTIME` used for sleep or duration calculation
- Thread constructed without `MakeConfig()` specifying SCHED_FIFO and priority
- `mlockall` not called before starting RT threads (App not used, raw threads used instead)
- rtprio set to 99 (blocks kernel watchdog)
- `std::this_thread::sleep_for` used instead of `clock_nanosleep` with `TIMER_ABSTIME`
- Logging with `std::cout`, `printf`, or `spdlog` directly inside `Loop()` (use Quill via `LOG_INFO(Logger(), ...)`)
- ROS 2 publisher called directly inside `Loop()` without the cactus-rt safe passthrough
- `Loop()` not marked `noexcept`
- Priority inheritance not considered when `cactus_rt::mutex` critical section contains non-RT-safe code

## Anti-Patterns

- Using `std::mutex` for RT/non-RT thread communication
- Calling `rclcpp::spin` in the RT thread
- Emitting ROS 2 messages directly from `Loop()` via raw publisher
- Using `sleep_for` or `usleep` for loop timing instead of absolute-time nanosleep
- Heap-allocating in `Loop()` with `new`, `std::make_shared`, or inserting into non-reserved containers
- Running rtprio=99 for user RT threads
- Skipping mlockall (not using `cactus_rt::App`)
- Using CLOCK_REALTIME for elapsed time or jitter measurement
- Logging with blocking loggers (`std::cout`, sync `spdlog`) inside `Loop()`
- Deploying without running cyclictest to verify scheduling latency on target hardware

## Quick Checklist

- [ ] `cactus_rt::App` is constructed first; mlockall called automatically
- [ ] RT thread inherits CyclicThread, `MakeConfig()` sets period + SCHED_FIFO + rtprio=80
- [ ] `Loop()` is marked `noexcept`
- [ ] No dynamic memory allocation inside `Loop()`
- [ ] No `std::mutex` used in any RT path, replaced with `cactus_rt::mutex` or lockless queue
- [ ] `CLOCK_MONOTONIC` used for all time measurements; `CLOCK_REALTIME` not used
- [ ] `rclcpp::spin` runs in a separate non-RT thread, not inside `Loop()`
- [ ] ROS 2 data exchange uses cactus-rt `ReadLatest()` / `Publish()` passthrough
- [ ] Logging inside `Loop()` uses Quill via `LOG_INFO(Logger(), ...)` only
- [ ] RT thread pinned to isolated CPU via `cpu_affinity` in `CyclicThreadConfig` where jitter is critical
- [ ] `/proc/sys/kernel/sched_rt_runtime_us` set to `-1` (RT throttling disabled)
- [ ] Dynamic frequency scaling disabled in BIOS/UEFI and CPU governor set to performance
- [ ] System validated with cyclictest under stress-ng load before deployment
- [ ] Perfetto tracing added to critical sections of `Loop()` for latency profiling
- [ ] Critical section code inside `cactus_rt::mutex` lock is itself RT-safe (no alloc, no blocking)

## Good References

- cactus-rt GitHub repository: https://github.com/SasaKuruppuarachchi/agipix-rt
- Shuhao Wu, Linux RT App Dev Part 1 (What is RT?): https://shuhaowu.com/blog/2022/01-linux-rt-appdev-part1.html
- Shuhao Wu, Linux RT App Dev Part 2 (Configuring Linux for RT): https://shuhaowu.com/blog/2022/02-linux-rt-appdev-part2.html
- Shuhao Wu, Linux RT App Dev Part 3 (Sources of Latency): https://shuhaowu.com/blog/2022/03-linux-rt-appdev-part3.html
- Shuhao Wu, Linux RT App Dev Part 4 (C++ Tutorial): https://shuhaowu.com/blog/2022/04-linux-rt-appdev-part4.html
- Perfetto trace viewer: https://ui.perfetto.dev
- PREEMPT_RT wiki: https://wiki.linuxfoundation.org/realtime/start