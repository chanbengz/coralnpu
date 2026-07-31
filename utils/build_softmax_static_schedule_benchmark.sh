#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${script_dir}/build_riscv_benchmark.sh" softmax_static_schedule_benchmark "$@"
