# Accuracy and interpretation

BSTVC Monitor is designed to make an INLA run easier to compare against Windows Task Manager and against other thread configurations. It is a measurement aid, not a replacement for Task Manager, the model log, or scientific validation.

## CPU definitions

The primary dashboard uses the `cpu_pct_total` series. It estimates the process CPU share on a whole-machine scale and limits the displayed value to 0–100%. This is the scale that should be compared with the Windows Task Manager **Processes** page.

Windows counters can also expose process utility or logical-core-style values. A process using more than one logical core can produce values above 100% on those scales. BSTVC Monitor keeps those values in advanced diagnostics so the main decision curve remains readable.

The monitor and Task Manager do not necessarily sample at the same instant. A short mismatch is therefore normal. For a meaningful check, align timestamps, compare the same process, and compare an average over a window rather than one instantaneous point.

## Memory definitions

The main memory series uses Working Set: physical memory currently resident for the process. It is useful for judging whether a workstation is approaching practical memory pressure, but it is not the same as the full committed/private allocation. Windows may trim or restore Working Set pages without the model itself changing, so interpret a short movement together with page faults, I/O, and the process state.

The page stores memory in GB for readability. Raw values and the complete CSV remain available for reproducibility.

## Threads and phases

Thread counts are sampled from the process and summarized as current, average, and peak values when Windows exposes them. A high thread count is not automatically efficient: synchronization, scheduling, memory bandwidth, and I/O can all limit useful parallelism.

Stage labels are evidence-based hints. Warm-up usually has short or changing activity; effective computation tends to show sustained CPU; I/O or low-load stages show lower CPU together with disk activity, page faults, or a stable waiting pattern. The label and confidence should be read with the raw curves, not treated as a ground-truth profiler trace.

## Recommended comparison protocol

1. Keep model, data, initialization, convergence criteria, INLA version, and machine state constant.
2. Compare the same post-start duration, such as the first 30 minutes, or compare complete runs when all runs finish.
3. Use average CPU and effective-compute average first; then inspect runtime, stability, memory headroom, I/O, and context-switch/page-fault symptoms.
4. Repeat promising configurations. Treat a recommendation as stable only when it remains similar across a reasonable time window and repeated run.
5. Verify convergence, warnings, numerical output, and scientific conclusions separately.

## Known limitations

- Sampling latency means an instantaneous dashboard value will not always equal the value visible in Task Manager at the moment of comparison.
- Windows performance counters can be unavailable, delayed, or permission-limited. Missing advanced fields do not necessarily mean basic collection failed.
- Automatic phase detection is a practical classification from observed metrics, not a direct trace of INLA internals.
- A high average CPU can coexist with a long runtime or an unacceptable memory cost. The composite score is decision support, not a universal efficiency theorem.
- The monitor observes the process named `inla.exe`; it does not inspect model syntax, result quality, or convergence internals.
