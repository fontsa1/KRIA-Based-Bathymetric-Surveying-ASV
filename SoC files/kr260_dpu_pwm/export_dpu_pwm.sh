#!/usr/bin/env bash
# export_dpu_pwm.sh -- gather what is needed to share the KR260 DPU + 2-PWM design.
# Run in Ubuntu (WSL) after the bitstream is built and board/package_app.sh has run:
#   bash "/mnt/d/School/Senior Design/KRIA-Based-Bathymetric-Surveying-ASV/SoC files/kr260_dpu_pwm/export_dpu_pwm.sh"
#   1. copies the small Vitis settings files (dpu_conf.vh, prj_config*, *.cfg, project files) into vitis/   -> git
#   2. if the platform's own Vivado project is on this laptop, saves it as Tcl in platform/              -> git
#      (set PLATFORM_XPR=/path/to/project.xpr if it isn't found automatically)
#   3. fills release_kr260_dpu_pwm/ NEXT TO the repo (never committed) with the GitHub Release files:
#        kr260_pwm_app.tar.gz            board package: bit.bin, dtbo, shell.json, install_on_board.sh, pwm_test.py
#        kr260_dpu_pwm.bit .hwh .xclbin  bitstream with the PWM patch, its hardware handoff, the DPU xclbin
#        kr260_pwm.xsa                   fixed XSA (bitstream inside) for PetaLinux / Vitis software
#        amd_contest_design.xsa          the platform XSA the Vitis build starts from
#        SHA256SUMS.txt  RELEASE_NOTES.md
# It never commits, pushes or uploads anything; README.md says how to do those.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
KR="${KR:-$HOME/kr260}"
WS="${WS:-$KR/KR260_tutorial/vitis_workspace}"
REL="${RELEASE_DIR:-$(dirname "$REPO")/release_kr260_dpu_pwm}"
SETTINGS="${XILINX_SETTINGS:-/tools/Xilinx/Vitis/2023.1/settings64.sh}"
APP=kr260_pwm
HWL="$(ls -d "$WS"/*_system_hw_link 2>/dev/null | head -1)"
PRJ="$HWL/Hardware/dpu.build/link/vivado/vpl/prj"
BIT="$PRJ/prj.runs/impl_1/design_1_wrapper.bit"
HWH="$PRJ/prj.gen/sources_1/bd/design_1/hw_handoff/design_1.hwh"
XCLBIN="$HWL/Hardware/dpu.xclbin"
APPDIR="$KR/$APP"
FIXED_XSA="$KR/${APP}_build/$APP.xsa"
PLAT_XSA="$KR/KR260_tutorial/amd_contest_design.xsa"
winpath() { wslpath -w "$1" 2>/dev/null || echo "$1"; }

[ -n "$HWL" ] || { echo "!! no *_system_hw_link project in $WS"; exit 1; }
[ -f "$BIT" ] || { echo "!! no bitstream yet: $BIT"; exit 1; }
BD="$(find "$PRJ" -path '*sources_1/bd/design_1/design_1.bd' 2>/dev/null | head -1)"
if [ -n "$BD" ] && ! grep -q axi_timer_0 "$BD"; then
  echo "!! the Vitis project has no PWM blocks (a Vitis rebuild replaces it): run vivado/add_pwm_gpio.tcl"
  echo "   on $PRJ/prj.xpr, generate the bitstream, run board/package_app.sh, then this script again."; exit 1
fi
for f in "$APPDIR/$APP.bit.bin" "$FIXED_XSA"; do
  if [ ! -f "$f" ] || [ "$BIT" -nt "$f" ]; then
    echo "!! $f is missing or older than the bitstream -- run board/package_app.sh first"; exit 1
  fi
done

echo "== [1/3] Vitis settings -> $HERE/vitis/"
mkdir -p "$HERE/vitis"
n=0
while IFS= read -r -d '' f; do
  rel="${f#"$WS"/}"
  mkdir -p "$HERE/vitis/$(dirname "$rel")"
  if ! cmp -s "$f" "$HERE/vitis/$rel"; then cp -f "$f" "$HERE/vitis/$rel"; echo "   copied $rel"; fi
  n=$((n + 1))
done < <(find "$WS" -mindepth 2 -maxdepth 7 -type f \
           \( -name dpu_conf.vh -o -name 'prj_config*' -o -name '*.cfg' -o -name '*.prj' -o -name '*.sprj' -o -name '*.spr' \) \
           -not -path '*/.metadata/*' -not -path '*/Hardware/*' -not -path '*/Emulation*/*' -not -path '*/_x/*' \
           -not -path '*/_ide/*' -not -path '*/export/*' -not -path '*/.Xil/*' -not -path '*/Debug/*' \
           -not -path '*/Release/*' -size -1024k -print0 | sort -z)
echo "   $n file(s) checked (they contain this laptop's paths: use them as a reference for the Vitis settings)"

echo "== [2/3] platform Vivado project -> $HERE/platform/"
PLAT_XPR="${PLATFORM_XPR:-}"
if [ -z "$PLAT_XPR" ]; then
  mapfile -t XPRS < <(find "$KR" -maxdepth 4 -name '*.xpr' -not -path '*/vitis_workspace/*' \
                        -not -path '*/_old_copies/*' -not -path '*_build/*' 2>/dev/null)
  for x in "${XPRS[@]}"; do
    [ "$(basename "$x" .xpr)" = "$(basename "$PLAT_XSA" .xsa)" ] && PLAT_XPR="$x"
  done
fi
if [ -n "$PLAT_XPR" ]; then
  echo "   exporting $PLAT_XPR (Vivado batch, about a minute)"
  TMPD="$(mktemp -d)"
  set +u; source "$SETTINGS" >/dev/null 2>&1; set -u
  ( cd "$TMPD" && vivado -mode batch -nojournal -nolog -source "$REPO/SoC files/scripts/export_project.tcl" \
      -tclargs "$PLAT_XPR" "$HERE/platform" ) > "$TMPD/export.out" 2>&1
  grep -E '^(EXPORT|ERROR)' "$TMPD/export.out" | sed 's/^/   /'
  grep -q '^EXPORT: done' "$TMPD/export.out" || echo "   !! platform export failed (full log: $TMPD/export.out)"
else
  echo "   no $(basename "$PLAT_XSA" .xsa).xpr under $KR -- skipped (the Release carries the XSA instead)"
  for x in "${XPRS[@]}"; do echo "   other Vivado project: $x"; done
  echo "   if one of those made the XSA:  PLATFORM_XPR=/path/to/it.xpr bash \"$0\""
fi

echo "== [3/3] GitHub Release files -> $REL"
mkdir -p "$REL"
missing=0
add() {
  if [ -f "$1" ]; then cp -f "$1" "$REL/$2"; printf '   %-28s %s\n' "$2" "$(du -h "$REL/$2" | cut -f1)"
  else echo "   !! $1 not found -- $2 left out"; missing=$((missing + 1)); fi
}
tar -C "$KR" -czf "$REL/${APP}_app.tar.gz" "$APP" && printf '   %-28s %s\n' "${APP}_app.tar.gz" "$(du -h "$REL/${APP}_app.tar.gz" | cut -f1)"
add "$BIT"       kr260_dpu_pwm.bit
add "$HWH"       kr260_dpu_pwm.hwh
add "$XCLBIN"    kr260_dpu_pwm.xclbin
add "$FIXED_XSA" kr260_pwm.xsa
add "$PLAT_XSA"  amd_contest_design.xsa
( cd "$REL" && sha256sum -- "${APP}_app.tar.gz" kr260_dpu_pwm.* *.xsa 2>/dev/null > SHA256SUMS.txt )

RPT="$PRJ/prj.runs/impl_1/design_1_wrapper_timing_summary_routed.rpt"
TIMING="see the impl_1 timing report"
if [ -f "$RPT" ]; then
  TIMING="$(awk '/Design Timing Summary/{f=1} f && $1 ~ /^-?[0-9]+\.[0-9]+$/ {print "WNS " $1 " ns, WHS " $5 " ns"; exit}' "$RPT")"
fi
cat > "$REL/RELEASE_NOTES.md" <<NOTES
KR260 DPU (DPUCZDX8G, KR260 DPU tutorial) plus 2 AXI Timer PWMs and 1 GPIO enable on PMOD1.
Bitstream built $(date -r "$BIT" '+%Y-%m-%d %H:%M') with Vivado 2023.1: Vitis v++ link, then
\`SoC files/kr260_dpu_pwm/vivado/add_pwm_gpio.tcl\`. Timing: $TIMING.

| Port | Driven by | Address | KR260 pin |
| --- | --- | --- | --- |
| PWM_0 | axi_timer_1/pwm0 | 0xA003_0000 | H12 (PMOD1 upper row, pin 1) |
| PWM_1 | axi_timer_0/pwm0 | 0xA002_0000 | E10 (PMOD1 upper row, pin 2) |
| enable | axi_gpio_0 bit 0 | 0xA001_0000 | B10 (PMOD1 lower row, pin 1) |

**Files**
- \`kr260_pwm_app.tar.gz\`: board package. On the KR260: \`tar xzf kr260_pwm_app.tar.gz && cd kr260_pwm && bash install_on_board.sh\`, then \`sudo python3 pwm_test.py\`.
- \`kr260_dpu_pwm.bit\`: full bitstream with the PWM blocks. \`kr260_dpu_pwm.hwh\`: its hardware handoff (address map).
- \`kr260_dpu_pwm.xclbin\`: DPU kernel container from the v++ link (made before the PWM patch).
- \`kr260_pwm.xsa\`: fixed hardware platform with the bitstream, for PetaLinux or Vitis software projects.
- \`amd_contest_design.xsa\`: the extensible platform the Vitis build starts from.
- \`SHA256SUMS.txt\`: check downloads with \`sha256sum -c SHA256SUMS.txt\`.

Source (Tcl, constraints, Vitis settings) is in \`SoC files/kr260_dpu_pwm/\` at this release's tag.
NOTES
echo "   SHA256SUMS.txt, RELEASE_NOTES.md"
[ "$missing" -eq 0 ] || echo "   !! $missing file(s) missing -- see above"

cat <<NEXT

EXPORT_DONE
1. git: commit "SoC files/kr260_dpu_pwm" (scripts, vitis/, platform/) and push.
2. GitHub: Releases > Draft a new release > tag kr260-dpu-pwm-v1 (v2, v3 ... later) > target main >
   drag in every file from $(winpath "$REL")
   > paste RELEASE_NOTES.md into the description > Publish release.
NEXT
