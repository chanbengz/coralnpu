#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${repo_root}/.cache/synthesis"
published_summary="${repo_root}/doc/out_of_order_area_results.json"
lib_dir="${output_dir}/lib"
liberty="${lib_dir}/NangateOpenCellLibrary_typical.lib"
liberty_commit="10d4ff741be3d7b806a9c289e7adc3e9fb69e8c3"
liberty_sha256="8d540a4d4cf6d09d27c87ad067857a9c0c2eeb023ab7a56e058cd3113db4e9b1"
liberty_url="https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/${liberty_commit}/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib"

for tool in awk bazel curl git jq mktemp perl sha256sum sv2v uname yosys yosys-abc; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "error: ${tool} is required for area synthesis" >&2
    exit 1
  fi
done

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

mkdir -p "${lib_dir}"
actual_sha256=""
if [[ -f "${liberty}" ]]; then
  actual_sha256="$(sha256_file "${liberty}")"
fi

if [[ "${actual_sha256}" != "${liberty_sha256}" ]]; then
  liberty_download="$(mktemp "${liberty}.tmp.XXXXXX")"
  if ! curl -L --fail --silent --show-error "${liberty_url}" -o "${liberty_download}"; then
    rm -f "${liberty_download}"
    exit 1
  fi
  downloaded_sha256="$(sha256_file "${liberty_download}")"
  if [[ "${downloaded_sha256}" != "${liberty_sha256}" ]]; then
    echo "error: unexpected downloaded Nangate45 Liberty checksum: ${downloaded_sha256}" >&2
    rm -f "${liberty_download}"
    exit 1
  fi
  mv "${liberty_download}" "${liberty}"
fi

cd "${repo_root}"
bazel build \
  //hdl/chisel/src/coralnpu:core_mini_area_axi_cc_library_emit_verilog \
  //hdl/chisel/src/coralnpu:core_mini_area_inorder16_axi_cc_library_emit_verilog \
  //hdl/chisel/src/coralnpu:core_mini_area_ooo_axi_cc_library_emit_verilog

synthesize() {
  local label="$1"
  local top="$2"
  local generated_sv="bazel-bin/hdl/chisel/src/coralnpu/${top}.sv"
  local converted_v="${output_dir}/${top}.v"
  local stat_json="${output_dir}/${label}_stat.json"
  local log_file="${output_dir}/${label}_synth.log"

  sv2v \
    -D SYNTHESIS \
    -D VERILATOR \
    --top="${top}" \
    --write="${converted_v}" \
    "${generated_sv}"

  # FPnew emits elaboration-only severity tasks, including tasks inside
  # constant helper functions. Yosys cannot parse those function-side tasks.
  # Remove only the generated Fatal/Warning task lines; datapath statements and
  # the helper functions' conservative default return values remain intact.
  perl -ni -e '
    next if /^\s*\$display\("(?:Fatal|Warning) /;
    next if /^\s*\$finish\(1\);\s*$/;
    print;
  ' "${converted_v}"

  yosys -Q -T -q -l "${log_file}" -p "
    read_verilog ${converted_v};
    blackbox Sram;
    hierarchy -top ${top};
    synth -top ${top};
    dfflibmap -liberty ${liberty};
    abc -liberty ${liberty};
    clean -purge;
    tee -o ${stat_json} stat -top ${top} -liberty ${liberty} -json;
  "

  jq -e \
    --arg top "\\${top}" \
    '
      .design.area > 0
      and .design.num_cells > 0
      and .design.num_cells_by_type.Sram == 2
      and .modules[$top].area > 0
    ' "${stat_json}" >/dev/null
}

synthesize baseline CoreMiniAreaAxi
synthesize inorder16 CoreMiniAreaInOrder16Axi
synthesize ooo CoreMiniAreaOooAxi

jq -e \
  '.modules["\\OutOfOrderIssueQueue"].area > 0' \
  "${output_dir}/ooo_stat.json" >/dev/null

yosys_version="$(yosys -V)"
sv2v_version="$(sv2v --version)"
abc_version="$(yosys-abc -c 'version; quit' 2>&1 | awk '/UC Berkeley, ABC/{print; exit}')"
rtl_git_commit="$(git rev-parse HEAD)"
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

summary_json="${output_dir}/area_summary.json"
jq -n \
  --arg yosys_version "${yosys_version}" \
  --arg sv2v_version "${sv2v_version}" \
  --arg abc_version "${abc_version}" \
  --arg liberty_commit "${liberty_commit}" \
  --arg liberty_sha256 "${liberty_sha256}" \
  --arg host_os "$(uname -s)" \
  --arg host_arch "$(uname -m)" \
  --arg rtl_git_commit "${rtl_git_commit}" \
  --arg rtl_source_diff_sha256 "${rtl_source_diff_sha256}" \
  --argjson rtl_git_dirty "${rtl_git_dirty}" \
  --arg baseline_rtl_sha256 "$(sha256_file "${output_dir}/CoreMiniAreaAxi.v")" \
  --arg inorder16_rtl_sha256 "$(sha256_file "${output_dir}/CoreMiniAreaInOrder16Axi.v")" \
  --arg ooo_rtl_sha256 "$(sha256_file "${output_dir}/CoreMiniAreaOooAxi.v")" \
  --slurpfile baseline "${output_dir}/baseline_stat.json" \
  --slurpfile inorder16 "${output_dir}/inorder16_stat.json" \
  --slurpfile ooo "${output_dir}/ooo_stat.json" \
  '{
    methodology: {
      yosys: $yosys_version,
      abc: $abc_version,
      sv2v: $sv2v_version,
      library: "NangateOpenCellLibrary typical, 45 nm",
      liberty_commit: $liberty_commit,
      liberty_sha256: $liberty_sha256,
      host_os: $host_os,
      host_arch: $host_arch,
      scope: "CoreMini scalar+FP+AXI standard-cell logic; RVV disabled",
      configuration: {
        enable_rvv: false,
        enable_vme: false,
        enable_float: true,
        enable_zfbfmin: true,
        fetch_data_bits: 128,
        lsu_data_bits: 128,
        use_axi: true,
        expose_debug_trace_ports: false
      },
      timing_constraint: "none (area-oriented mapping)",
      synthesis_pass: "Yosys synth, dfflibmap, and ABC liberty mapping",
      defines: ["SYNTHESIS", "VERILATOR"],
      sram_handling: "8 KiB ITCM and 32 KiB DTCM Sram leaves black-boxed in every configuration",
      unpriced_generic_cells: {
        baseline:
          ($baseline[0].design.num_cells_by_type
           | with_entries(select(.key | startswith("$_")))),
        inorder16:
          ($inorder16[0].design.num_cells_by_type
           | with_entries(select(.key | startswith("$_")))),
        ooo:
          ($ooo[0].design.num_cells_by_type
           | with_entries(select(.key | startswith("$_"))))
      }
    },
    rtl: {
      git_commit: $rtl_git_commit,
      dirty_worktree: $rtl_git_dirty,
      source_diff_sha256: $rtl_source_diff_sha256,
      baseline: {
        top: "CoreMiniAreaAxi",
        converted_verilog_sha256: $baseline_rtl_sha256
      },
      inorder16: {
        top: "CoreMiniAreaInOrder16Axi",
        converted_verilog_sha256: $inorder16_rtl_sha256
      },
      ooo: {
        top: "CoreMiniAreaOooAxi",
        converted_verilog_sha256: $ooo_rtl_sha256
      }
    },
    baseline_rob8: {
      area_um2: $baseline[0].design.area,
      sequential_area_um2: $baseline[0].design.sequential_area,
      cells: $baseline[0].design.num_cells
    },
    inorder_rob16: {
      area_um2: $inorder16[0].design.area,
      sequential_area_um2: $inorder16[0].design.sequential_area,
      cells: $inorder16[0].design.num_cells
    },
    ooo_rob16: {
      area_um2: $ooo[0].design.area,
      sequential_area_um2: $ooo[0].design.sequential_area,
      cells: $ooo[0].design.num_cells
    },
    retirement_config_8_to_16: {
      delta_um2: ($inorder16[0].design.area - $baseline[0].design.area),
      overhead_percent:
        (100 * ($inorder16[0].design.area - $baseline[0].design.area)
         / $baseline[0].design.area)
    },
    dynamic_issue_matched_rob: {
      delta_um2: ($ooo[0].design.area - $inorder16[0].design.area),
      overhead_percent:
        (100 * ($ooo[0].design.area - $inorder16[0].design.area)
         / $inorder16[0].design.area)
    },
    total_feature: {
      delta_um2: ($ooo[0].design.area - $baseline[0].design.area),
      overhead_percent:
        (100 * ($ooo[0].design.area - $baseline[0].design.area)
         / $baseline[0].design.area)
    },
    issue_queue: {
      area_um2: $ooo[0].modules["\\OutOfOrderIssueQueue"].area,
      sequential_area_um2:
        $ooo[0].modules["\\OutOfOrderIssueQueue"].sequential_area
    }
  }' >"${summary_json}"

cp "${summary_json}" "${published_summary}"
jq . "${published_summary}"
