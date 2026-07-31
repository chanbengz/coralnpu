#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
published_summary="${repo_root}/doc/out_of_order_performance_results.json"
runs="${RUNS:-3}"

if ((runs < 1 || runs % 2 == 0)); then
  echo "error: RUNS must be a positive odd number" >&2
  exit 1
fi

for tool in awk bazel git jq sha256sum sort uname; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "error: ${tool} is required for the performance experiment" >&2
    exit 1
  fi
done

cd "${repo_root}"
naive_elf="$("${repo_root}/utils/build_softmax_benchmark.sh")"
static_elf="$("${repo_root}/utils/build_softmax_static_schedule_benchmark.sh")"

bazel build \
  //tests/verilator_sim:core_mini_axi_sim \
  //tests/verilator_sim:core_mini_inorder16_axi_sim \
  //tests/verilator_sim:core_mini_ooo_axi_sim

baseline_bin="${repo_root}/bazel-bin/tests/verilator_sim/core_mini_axi_sim"
inorder16_bin="${repo_root}/bazel-bin/tests/verilator_sim/core_mini_inorder16_axi_sim"
ooo_bin="${repo_root}/bazel-bin/tests/verilator_sim/core_mini_ooo_axi_sim"
verilator_bin="${repo_root}/bazel-bin/external/verilator/verilator_bin"
clang_bin="${CORALNPU_LLVM_CLANG:-$(command -v clang)}"
lld_bin="${CORALNPU_LD_LLD:-$(command -v ld.lld)}"

for artifact in \
  "${baseline_bin}" \
  "${inorder16_bin}" \
  "${ooo_bin}" \
  "${verilator_bin}" \
  "${clang_bin}" \
  "${lld_bin}"; do
  if [[ ! -x "${artifact}" ]]; then
    echo "error: expected executable not found: ${artifact}" >&2
    exit 1
  fi
done

run_model() {
  local binary="$1"
  local elf="$2"
  local label="$3"
  local output
  local cycles

  for ((run = 1; run <= runs; run++)); do
    output="$(
      "${binary}" \
        --binary="${elf}" \
        --backdoor_load=true \
        --cycles=1000000 2>&1
    )"
    cycles="$(awk '/^Benchmark cycles:/{print $3; exit}' <<<"${output}")"
    if [[ ! "${cycles}" =~ ^[0-9]+$ ]]; then
      echo "error: ${label} run ${run} did not report benchmark cycles" >&2
      printf '%s\n' "${output}" >&2
      exit 1
    fi
    printf '%s\n' "${cycles}"
  done
}

mapfile -t naive_baseline_cycles < <(
  run_model "${baseline_bin}" "${naive_elf}" naive_inorder_rob8
)
mapfile -t static_baseline_cycles < <(
  run_model "${baseline_bin}" "${static_elf}" static_scheduled_inorder_rob8
)
mapfile -t naive_inorder16_cycles < <(
  run_model "${inorder16_bin}" "${naive_elf}" naive_inorder_rob16
)
mapfile -t static_inorder16_cycles < <(
  run_model "${inorder16_bin}" "${static_elf}" static_scheduled_inorder_rob16
)
mapfile -t naive_ooo_cycles < <(
  run_model "${ooo_bin}" "${naive_elf}" naive_ooo_rob16
)

median() {
  printf '%s\n' "$@" |
    sort -n |
    awk -v middle="$(((runs + 1) / 2))" 'NR == middle { print; exit }'
}

json_array() {
  printf '%s\n' "$@" | jq -R 'tonumber' | jq -s .
}

naive_baseline_median="$(median "${naive_baseline_cycles[@]}")"
static_baseline_median="$(median "${static_baseline_cycles[@]}")"
naive_inorder16_median="$(median "${naive_inorder16_cycles[@]}")"
static_inorder16_median="$(median "${static_inorder16_cycles[@]}")"
naive_ooo_median="$(median "${naive_ooo_cycles[@]}")"
rtl_source_diff_sha256="$(
  # Hash implementation and experiment inputs only. Documentation and generated
  # reports can then be updated without invalidating the recorded source state.
  git diff --binary HEAD -- examples hdl tests utils |
    sha256sum |
    awk '{print $1}'
)"

if [[ -n "$(git status --porcelain --untracked-files=normal -- examples hdl tests utils)" ]]; then
  rtl_git_dirty=true
else
  rtl_git_dirty=false
fi

jq -n \
  --arg host_os "$(uname -s)" \
  --arg host_arch "$(uname -m)" \
  --arg bazel_version "$(bazel --version)" \
  --arg verilator_version "$("${verilator_bin}" --version)" \
  --arg clang_version "$("${clang_bin}" --version | awk 'NR == 1')" \
  --arg lld_version "$("${lld_bin}" --version | awk 'NR == 1')" \
  --arg git_commit "$(git rev-parse HEAD)" \
  --arg source_diff_sha256 "${rtl_source_diff_sha256}" \
  --argjson dirty_worktree "${rtl_git_dirty}" \
  --arg naive_elf_sha256 "$(sha256sum "${naive_elf}" | awk '{print $1}')" \
  --arg static_elf_sha256 "$(sha256sum "${static_elf}" | awk '{print $1}')" \
  --arg baseline_sim_sha256 "$(sha256sum "${baseline_bin}" | awk '{print $1}')" \
  --arg inorder16_sim_sha256 "$(sha256sum "${inorder16_bin}" | awk '{print $1}')" \
  --arg ooo_sim_sha256 "$(sha256sum "${ooo_bin}" | awk '{print $1}')" \
  --argjson naive_baseline_cycles "$(json_array "${naive_baseline_cycles[@]}")" \
  --argjson static_baseline_cycles "$(json_array "${static_baseline_cycles[@]}")" \
  --argjson naive_inorder16_cycles "$(json_array "${naive_inorder16_cycles[@]}")" \
  --argjson static_inorder16_cycles "$(json_array "${static_inorder16_cycles[@]}")" \
  --argjson naive_ooo_cycles "$(json_array "${naive_ooo_cycles[@]}")" \
  --argjson naive_baseline_median "${naive_baseline_median}" \
  --argjson static_baseline_median "${static_baseline_median}" \
  --argjson naive_inorder16_median "${naive_inorder16_median}" \
  --argjson static_inorder16_median "${static_inorder16_median}" \
  --argjson naive_ooo_median "${naive_ooo_median}" \
  '
  def result($cycles; $median):
    {
      cycles: $cycles,
      median_cycles: $median
    };
  def improvement($before; $after):
    {
      cycles_saved: ($before - $after),
      cycle_reduction_percent: (100 * ($before - $after) / $before),
      speedup: ($before / $after)
    };
  {
    methodology: {
      host_os: $host_os,
      host_arch: $host_arch,
      bazel: $bazel_version,
      verilator: $verilator_version,
      clang: $clang_version,
      lld: $lld_version,
      benchmark: "softmax-inspired scalar integer divide-latency scheduling analogue",
      benchmark_variants: {
        naive:
          "dependent context-A normalization precedes independent context-B work",
        static_scheduled:
          "context-B work is manually interleaved across context-A divide latency"
      },
      measured_counter: "mcycle reset immediately before the repeated kernel",
      runs_per_configuration: ($naive_baseline_cycles | length),
      simulator_limit_cycles: 1000000,
      simulator_targets: [
        "//tests/verilator_sim:core_mini_axi_sim",
        "//tests/verilator_sim:core_mini_inorder16_axi_sim",
        "//tests/verilator_sim:core_mini_ooo_axi_sim"
      ],
      benchmark_compile_flags: [
        "--target=riscv32-unknown-elf",
        "-march=rv32im_zicsr",
        "-mabi=ilp32",
        "-mno-relax",
        "-nostdlib",
        "-fuse-ld=lld",
        "-Wl,--no-relax",
        "-Wl,--gc-sections"
      ]
    },
    source: {
      git_commit: $git_commit,
      dirty_worktree: $dirty_worktree,
      source_diff_sha256: $source_diff_sha256,
      elf_sha256: {
        naive: $naive_elf_sha256,
        static_scheduled: $static_elf_sha256
      },
      simulator_sha256: {
        inorder_rob8: $baseline_sim_sha256,
        inorder_rob16: $inorder16_sim_sha256,
        ooo_rob16: $ooo_sim_sha256
      }
    },
    configurations: {
      naive_inorder_rob8:
        result($naive_baseline_cycles; $naive_baseline_median),
      static_scheduled_inorder_rob8:
        result($static_baseline_cycles; $static_baseline_median),
      naive_inorder_rob16:
        result($naive_inorder16_cycles; $naive_inorder16_median),
      static_scheduled_inorder_rob16:
        result($static_inorder16_cycles; $static_inorder16_median),
      naive_ooo_rob16:
        result($naive_ooo_cycles; $naive_ooo_median)
    },
    comparisons: {
      ooo_vs_naive_inorder_matched_rob16:
        improvement($naive_inorder16_median; $naive_ooo_median),
      static_schedule_vs_naive_inorder_rob8:
        improvement($naive_baseline_median; $static_baseline_median),
      static_schedule_vs_naive_inorder_matched_rob16:
        improvement($naive_inorder16_median; $static_inorder16_median),
      ooo_vs_static_schedule_inorder_matched_rob16:
        improvement($static_inorder16_median; $naive_ooo_median),
      ooo_complete_configuration_vs_naive_inorder_rob8:
        improvement($naive_baseline_median; $naive_ooo_median)
    }
  }' >"${published_summary}"

jq . "${published_summary}"
