# Scalar Out-of-Order Issue Pipeline

## Existing pipeline

The scalar frontend fetches and decodes four instructions per cycle. Dispatch
uses scalar and floating-point scoreboards to reject RAW and WAW hazards, then
walks the lanes in order. When one lane cannot dispatch, all younger lanes stop.
The multiplier is pipelined, the divider is iterative, and the LSU and RVV
backend have their own queues. An eight-entry retirement buffer observes
completion and retires instructions in program order, but the frontend
previously had no way to issue around a blocked oldest instruction.

## Implementation

The optional `OutOfOrderIssueQueue` adds an age-ordered window for precisely
decoded scalar ALU, multiply, and divide instructions. The evaluation core
pairs a 16-entry issue window with a 16-entry retirement buffer:

- Fetch, issue-window allocation, and retirement-buffer allocation remain in
  program order. An executable invariant requires the queue and retirement
  buffer to accept the same maximal prefix atomically.
- Dependency and functional-unit metadata is decoded once when an instruction
  enters the window instead of instantiating a decoder for every resident slot.
- The oldest ready operations issue to the existing four execution lanes.
- A selected entry remains resident until the receiving execution path accepts
  it with a ready/valid `fire`; selection alone does not transfer ownership.
- RAW, WAR, and WAW dependencies are checked against every older queued
  operation and the existing in-flight scoreboard.
- At most one unfinished writer to an architectural scalar register is allowed.
  This is required because scalar completion is identified by architectural
  register number rather than a unique ROB tag.
- Multiply and divide remain single issue through lane zero; unrelated ALUs can
  bypass a busy unit.
- Loads/stores, control flow, CSRs, floating point, and RVV remain on the
  unchanged in-order path and act as full drain boundaries. A branch therefore
  cannot have younger scalar arithmetic in flight.
- Arithmetic results write the existing architectural register file at
  execution completion. The retirement buffer observes completion and retires
  bookkeeping in order; it is not a conventional result-holding commit ROB.
  Precision relies on the eligible operations being non-faulting and every
  potentially faulting or redirecting operation being a drained boundary.
- Trap flush, halt/interlock, single-step, and deferred external-debug entry
  close allocation at a precise boundary. No physical-register renaming,
  speculative memory ordering, or selective replay is introduced.

The default production configurations are unchanged. The feature is selected
with `--enableOutOfOrder=True`; `CoreMiniOooAxi` is the evaluation target.

## Reference-driven design boundary

Two downloaded architectural discussions sharpened both the implementation
invariants and the limits of this experiment:

- The [superscalar NPU
  discussion](https://zhuanlan.zhihu.com/p/2065903748623364818) separates
  dependency readiness from queue order, emphasizes atomic resource allocation,
  and keeps queue ownership until an execution unit actually accepts a command.
  Those points motivated the atomic queue/ROB assertions, the backpressure
  tests, and compact per-entry metadata. It also argues for coarse vector,
  matrix, and tile commands rather than placing every MAC in a CPU-like ROB.
- The [FlashAttention NPU
  discussion](https://www.zhihu.com/question/1964791844773822881/answer/1971378739620329005)
  makes the true dependency chain explicit: for one head and Q block,
  `BMM1 -> reduce-max -> exp -> row-sum/rescale -> BMM2` carries the online
  `m/l/O` state. OOO cannot remove that recurrence. Latency can only be hidden
  when another independent head or Q block is ready, which requires multiple
  live contexts and corresponding SRAM/UB capacity.

Both sources are informal architectural discussions, so this PR uses them to
form hypotheses and controls rather than as primary PPA evidence.

The present implementation is deliberately the scalar control-plane subset. It
does not reorder RVV, matrix, DMA, load/store, transpose/layout, barrier, or
online-softmax state updates. Expanding eligibility would first require unique
completion tags and result storage until retirement (or a physical-register
rename/commit design), plus selective kill/recovery. A natural NPU-specific
follow-on is a resource-aware macro-op scheduler with context IDs, dependency
tokens, buffer credits, and separate matrix/vector/DMA queues. Work within one
`m/l/O` context stays ordered while commands from other contexts may issue.
Window depth would then need to be swept together with context-buffer capacity,
not in isolation.

## Verification

The focused Chisel tests cover:

- bypass of a RAW-blocked instruction by younger independent ALUs;
- preservation of WAR ordering and rejection of duplicate unfinished
  destinations without register renaming;
- continued WAW exclusion while an older writer is owned by the scoreboard;
- bypass of a busy divider;
- ready/valid ownership under full-grant backpressure;
- simultaneous issue/allocation and survivor compaction; and
- complete issue-window squash on a retirement-buffer trap flush.

Run them with:

```bash
bazel test \
  //hdl/chisel/src/coralnpu:coralnpu_out_of_order_issue_queue_tests
```

The existing fetch/retirement test remains the regression baseline:

```bash
bazel test \
  //hdl/chisel/src/coralnpu:coralnpu_fetch_reorder_buffer_tests
```

On Linux x86_64 with Bazel 8.6.0, both focused targets pass against the final
post-flush-fix RTL. The three Verilator simulator targets used below also
elaborate and build successfully:
`core_mini_axi_sim`, `core_mini_inorder16_axi_sim`, and
`core_mini_ooo_axi_sim`.

## Performance experiment

The supplied [softmax scheduling
reference](https://zhuanlan.zhihu.com/p/29575167617) identifies the alternating
idle time in a sequential `reduce -> exp2 -> reduce` SIMD schedule and proposes
a sufficiently large OOO+SIMD instruction window to expose independent work.
The repository's materialized-score attention kernel implements safe softmax as
a vector reduce-max, subtraction of the maximum, polynomial exponential
approximation, reduce-sum, and vector division; it is not a tiled online
FlashAttention recurrence. The scalar issue window does not yet reorder RVV or
floating-point instructions, so `softmax_ooo_benchmark.S` is a fixed-point
scheduling analogue rather than a replacement for that kernel.

The benchmark processes two independent two-element contexts, representing
different heads or Q blocks rather than consecutive KV tiles of one online
softmax recurrence. It evaluates `x*x + x + 2` as a compact exponential
stand-in, reduces each context, uses the iterative integer divider for a
fixed-point reciprocal, and normalizes an element. Context B's independent
ALU/multiply work follows Context A's dependent normalization in the naive
program order, so dynamic issue can execute Context B while the divider is
busy. The `.rept` body deliberately unrolls four copies because every branch is
a full issue-window boundary. The kernel performs 256 copies total and validates
a checksum.

`softmax_static_schedule_benchmark.S` is an essential software-scheduling
control. It has the same measured-loop instruction multiset and result, but
manually moves Context B between Context A's divide and dependent multiply. This
tests whether a compiler or VLIW schedule can recover the fixed-latency
opportunity without dynamic hardware.

Run the complete reproducible comparison with:

```bash
./utils/run_ooo_performance.sh
```

The assembly resets `mcycle` immediately before the measured loop. The
simulator reports that counter at halt, excluding ELF loading and initialization
but including the small common checksum epilogue. The script executes three
runs of five configurations: naive and statically scheduled programs on the
8-entry baseline, the same pair on the matched 16-entry in-order control, and
the naive program on the 16-entry OOO core. Raw cycles, hashes, and derived
comparisons are recorded in
[`out_of_order_performance_results.json`](out_of_order_performance_results.json).
Every run must reach `tohost == 1`; the simulator exits unsuccessfully on a
checksum failure and the script stops immediately.

| Configuration | Measured cycles | Median |
| --- | --- | ---: |
| Naive, in-order, ROB 8 | 12,438; 12,436; 12,435 | 12,436 |
| Static schedule, in-order, ROB 8 | 10,389; 10,388; 10,388 | 10,388 |
| Naive, in-order, ROB 16 | 12,435; 12,435; 12,431 | 12,435 |
| Static schedule, in-order, ROB 16 | 10,388; 10,388; 10,388 | 10,388 |
| Naive, OOO, ROB/window 16 | 10,019; 10,020; 10,020 | 10,020 |

Against the matched 16-entry in-order control, dynamic issue saves 2,415
cycles, a **19.42% cycle reduction** or **1.241x speedup**. Static scheduling
recovers most of the opportunity on the in-order core: it saves 2,047 cycles,
a **16.46% cycle reduction** or **1.197x speedup**, accounting for 84.8% of the
cycles that OOO removes. The dynamically scheduled naive program is still 368
cycles faster than this fixed manual schedule on the in-order control, a
**3.54% cycle reduction** or **1.037x speedup**.

The relevant claims are intentionally separated:

- OOO versus naive in-order at matched ROB depth measures dynamic issue.
- Static versus naive on the same in-order core measures software scheduling.
- OOO-naive versus static-in-order measures the residual benefit over this one
  fixed manual schedule. Robustness to data-dependent latency or readiness is a
  motivation for dynamic scheduling, not a result measured by this experiment.

This is a divide-latency-hiding scalar analogue, not FlashAttention
acceleration. It contains no online `m/l/O` recurrence, RVV/matrix/DMA traffic,
layout/transpose, synchronization, SRAM backpressure, or useful-unit
utilization measurement. The execution latencies are fixed and there are no
cache misses or operand-dependent stalls; the observed one-to-four-cycle
spread is run/harness variation. It also does not measure placed-and-routed
frequency. The separate synthetic dependency benchmark remains available
through `./utils/build_ooo_benchmark.sh`.

## Area synthesis and scope

The archived Zhihu reference motivates the scheduling experiment but does not
specify a PPA tool or process. For a traceable open comparison, this repository
uses Yosys with ABC and the Nangate Open Cell Library typical 45 nm Liberty
file. The official
[OpenROAD flow](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts)
uses Yosys for logic synthesis, and published work has likewise evaluated
hardware with
[Yosys/OpenROAD and Nangate45](https://proceedings.neurips.cc/paper_files/paper/2024/file/fb23cf87a9e04d7677b73c47acd060ef-Paper-Conference.pdf).
This experiment only runs library-mapped synthesis; it does not run OpenROAD
placement or routing.

The Linux x86_64 run used Yosys 0.52, ABC 1.01, and sv2v 0.0.13. The Liberty
input is pinned to OpenROAD-flow-scripts commit
`10d4ff741be3d7b806a9c289e7adc3e9fb69e8c3` and SHA-256
`8d540a4d4cf6d09d27c87ad067857a9c0c2eeb023ab7a56e058cd3113db4e9b1`.
No clock constraint was applied, so these are area-oriented mapping results.

The comparison uses dedicated no-trace synthesis tops. It covers the
RVV-disabled `CoreMini` scalar core, floating-point unit, and AXI/TCM-wrapper
standard-cell logic. RVV, VME, and debug/trace ports are disabled. The 8 KiB
ITCM and 32 KiB DTCM have identical wrappers, but each complete `Sram` leaf is
black-boxed; both the memory array and its small leaf-local logic are therefore
absent from the totals. Two common generic latch cells are also unpriced by the
Liberty mapping. These are mapped-logic estimates, not final die dimensions.

Run the comparison with:

```bash
./utils/synthesize_ooo_area.sh
```

The script also synthesizes a matched 16-entry in-order control to separate the
larger retirement configuration from dynamic issue. Exact results and tool/RTL
hashes are recorded in
[`out_of_order_area_results.json`](out_of_order_area_results.json).

| Configuration | CoreMini mapped area (µm²) | Cell instances | Increase |
| --- | ---: | ---: | ---: |
| In-order, 8-entry retirement buffer | 193,525 | 129,856 | baseline |
| In-order, 16-entry retirement buffer | 212,424 | 142,245 | +9.77% |
| OOO, 16-entry retirement buffer/window | 249,751 | 171,110 | +29.05% |

Relative to the matched 16-entry in-order control, dynamic issue adds
37,327 µm² or **17.57%**. Relative to the 8-entry CoreMini proxy, the complete
evaluation configuration adds 56,226 µm² or **29.05%**:

- The complete 8-to-16-entry configuration delta is 18,899 µm². This includes
  retirement storage, propagated width/control changes, and mapper effects.
- The `OutOfOrderIssueQueue` hierarchy accounts for 35,920 µm².
- The residual integration/remapping difference is approximately 1,407 µm².

This is deliberately not labeled as whole-chip overhead. The complete Coral NPU
also contains vector and matrix execution resources, and the RVV-enabled
retirement buffer carries extra vector metadata. A full RVV synthesis attempt
did not complete within the local host's resource limits, and the open Nangate
input has no TCM macros. Therefore **29.05% is a CoreMini logic proxy, not an
NPU die-area percentage**.

It is also not an area estimate for full FlashAttention scheduling. Supporting
`C` live online-softmax contexts needs persistent state on the order of
`C * Br * (d_head + 2) * state_bits` for `O`, `m`, and `l`, plus schedule-dependent
`Br * Bc` score/probability tiles, ping-pong buffers, extra SRAM ports/banking,
matrix/vector/DMA queues, completion tokens, and cross-unit synchronization.
None of that storage or interconnect is present in this scalar CoreMini proxy.

At matched 16-entry retirement depth, combining the **1.176x** mapped-area
factor with the **1.241x** benchmark speedup gives **1.056x performance per
CoreMini proxy area**, a conditional 5.55% improvement. Comparing the complete
configuration with the default 8-entry proxy gives **0.962x**, a 3.83%
reduction. Both calculations assume unchanged clock frequency and do not
include SRAM macros, vector/matrix logic, routing, clock-tree overhead, power,
or post-layout timing.
