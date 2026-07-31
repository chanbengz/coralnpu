#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
benchmark_name="${1:?usage: build_riscv_benchmark.sh BENCHMARK_NAME [OUTPUT]}"
output="${2:-${repo_root}/.cache/benchmarks/${benchmark_name}.elf}"
source_file="${repo_root}/examples/${benchmark_name}.S"

if [[ ! -f "${source_file}" ]]; then
  echo "error: benchmark source not found: ${source_file}" >&2
  exit 1
fi

clang_bin="${CORALNPU_LLVM_CLANG:-$(command -v clang)}"
lld_bin="${CORALNPU_LD_LLD:-$(command -v ld.lld || true)}"

if [[ -z "${lld_bin}" ]]; then
  echo "error: ld.lld is required (set CORALNPU_LD_LLD or PATH)" >&2
  exit 1
fi

mkdir -p "$(dirname "${output}")"
PATH="$(dirname "${lld_bin}"):$(dirname "${clang_bin}"):${PATH}" \
  "${clang_bin}" \
  --target=riscv32-unknown-elf \
  -march=rv32im_zicsr \
  -mabi=ilp32 \
  -mno-relax \
  -nostdlib \
  -fuse-ld=lld \
  -Wl,--no-relax \
  -Wl,--gc-sections \
  -Wl,-T,"${repo_root}/examples/ooo_pipeline_benchmark.ld" \
  "${source_file}" \
  -o "${output}"

echo "${output}"
