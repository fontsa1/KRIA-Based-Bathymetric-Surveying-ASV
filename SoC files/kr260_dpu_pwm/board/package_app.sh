#!/usr/bin/env bash
# package_app.sh -- turn an implemented Vivado project into a KR260 app folder for `xmutil loadapp`.
# Run in Ubuntu (WSL) with Vivado + Vitis 2023.1 installed. With no options it packages the
# DPU + 2-PWM build (the Vitis-generated project patched by ../vivado/add_pwm_gpio.tcl):
#   bash package_app.sh
#   bash package_app.sh --xpr ~/vivado_builds/test1/test1.xpr --app test1
# Options:
#   --xpr <project.xpr>  implemented project            (default: the v++ project of the KR260 DPU tutorial)
#   --app <name>         app name = /lib/firmware/xilinx/<name> on the board   (default: kr260_pwm)
#   --out <folder>       where the app folder is written (default: ~/kr260/<name>)
# Makes <out>/: <app>.bit.bin, <app>.dtbo, shell.json, install_on_board.sh (+ pwm_test.py for kr260_pwm)
#   1. fixed XSA with the bitstream (Vivado batch, ~5-10 min)  -> <out>_build/<app>.xsa
#   2. device-tree overlay: xsct createdts -overlay -zocl + dtc (downloads device-tree-xlnx from GitHub)
#   3. bitstream -> <app>.bit.bin with bootgen
# If the project is open in a Vivado window, close it there first.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XPR="$HOME/kr260/KR260_tutorial/vitis_workspace/aiedge_system_hw_link/Hardware/dpu.build/link/vivado/vpl/prj/prj.xpr"
APP=kr260_pwm
OUT=""
SETTINGS="${XILINX_SETTINGS:-/tools/Xilinx/Vitis/2023.1/settings64.sh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --xpr) XPR="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "!! unknown option '$1' (see --help)"; exit 1 ;;
  esac
done
[ -n "$OUT" ] || OUT="$HOME/kr260/$APP"
WORK="${OUT}_build"
[ -f "$XPR" ] || { echo "!! project not found: $XPR  (use --xpr)"; exit 1; }
PRJ="$(cd "$(dirname "$XPR")" && pwd)"
NAME="$(basename "$XPR" .xpr)"
BIT="$(ls -t "$PRJ/$NAME.runs/impl_1/"*.bit 2>/dev/null | head -1)"
[ -n "$BIT" ] || { echo "!! no bitstream in $PRJ/$NAME.runs/impl_1 -- run Generate Bitstream first"; exit 1; }
set +u; source "$SETTINGS" >/dev/null 2>&1; set -u
for t in vivado xsct bootgen; do command -v "$t" >/dev/null || { echo "!! $t not found (settings: $SETTINGS)"; exit 1; }; done
command -v dtc >/dev/null || { echo "!! dtc not found - run: sudo apt install device-tree-compiler   then rerun"; exit 1; }
if pgrep -u "$(id -u)" -f 'lnx64.o/vivado' >/dev/null 2>&1; then
  echo "   note: a Vivado window is open -- if it has this project open, close the project there first"
fi
echo "app $APP from $BIT"
mkdir -p "$WORK" "$OUT"

echo "== [1/3] fixed XSA with the bitstream (about 5-10 minutes, quiet until done)"
if [ "$WORK/$APP.xsa" -nt "$BIT" ]; then
  echo "   up to date: $WORK/$APP.xsa"
else
  cat > "$WORK/export_xsa.tcl" <<TCL
open_project {$XPR}
open_run impl_1
write_hw_platform -fixed -include_bit -force -file {$WORK/$APP.xsa}
close_project
TCL
  ( cd "$WORK" && vivado -mode batch -nojournal -log export_xsa.log -source export_xsa.tcl ) > "$WORK/export_xsa.out" 2>&1
  [ -f "$WORK/$APP.xsa" ] && [ "$WORK/$APP.xsa" -nt "$BIT" ] || {
    echo "!! XSA export failed:"; grep -E '^(ERROR|CRITICAL)' "$WORK/export_xsa.out" | head; exit 1; }
  echo "   wrote $WORK/$APP.xsa"
fi

echo "== [2/3] device-tree overlay"
rm -rf "$WORK/dtg"
cat > "$WORK/dts.tcl" <<TCL
createdts -hw {$WORK/$APP.xsa} -zocl -out {$WORK/dtg} -platform-name $APP -git-branch xlnx_rel_v2023.1 -overlay
exit
TCL
( cd "$WORK" && xsct dts.tcl ) > "$WORK/dts.out" 2>&1
DTSI="$(find "$WORK/dtg" -name pl.dtsi 2>/dev/null | head -1)"
[ -n "$DTSI" ] || { echo "!! createdts made no pl.dtsi (it needs internet access to GitHub):"; tail -20 "$WORK/dts.out"; exit 1; }
sed -i -E "s/firmware-name = \"[^\"]*\";/firmware-name = \"$APP.bit.bin\";/" "$DTSI"
grep -q "firmware-name = \"$APP.bit.bin\"" "$DTSI" || { echo "!! pl.dtsi has no firmware-name line: $DTSI"; exit 1; }
dtc -@ -O dtb -o "$OUT/$APP.dtbo" "$DTSI" 2> "$WORK/dtc.warnings" || { echo "!! dtc failed:"; cat "$WORK/dtc.warnings"; exit 1; }
echo "   wrote $OUT/$APP.dtbo ($(grep -c -i warning "$WORK/dtc.warnings") dtc warnings, normal)"

echo "== [3/3] $APP.bit.bin, shell.json, board scripts"
printf 'all:\n{\n  [destination_device = pl] %s\n}\n' "$BIT" > "$WORK/$APP.bif"
bootgen -image "$WORK/$APP.bif" -arch zynqmp -o "$OUT/$APP.bit.bin" -w > "$WORK/bootgen.out" 2>&1 \
  || { echo "!! bootgen failed:"; cat "$WORK/bootgen.out"; exit 1; }
printf '{\n  "shell_type" : "XRT_FLAT",\n  "num_slots": "1"\n}\n' > "$OUT/shell.json"
cp -f "$HERE/install_on_board.sh" "$OUT/"
if [ "$APP" = kr260_pwm ]; then cp -f "$HERE/pwm_test.py" "$OUT/"; fi
chmod +x "$OUT/"*.sh "$OUT/"*.py 2>/dev/null
ls -la "$OUT"
cat <<NEXT

PACKAGE_DONE: $OUT
Copy it to the board and load it (you type the board's password):
  scp -r $OUT ubuntu@<board-ip>:~/
  ssh ubuntu@<board-ip>
  cd ~/$APP && bash install_on_board.sh
NEXT
