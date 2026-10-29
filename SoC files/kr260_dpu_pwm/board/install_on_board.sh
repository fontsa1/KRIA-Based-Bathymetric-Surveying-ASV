#!/usr/bin/env bash
# install_on_board.sh -- run ON THE KR260, inside the copied app folder:
#   cd ~/kr260_pwm && bash install_on_board.sh            (app name = the <app>.bit.bin in this folder)
#   bash install_on_board.sh <app>                        (pick one if the folder holds several)
# Installs the app into /lib/firmware/xilinx/<app> and loads it with xmutil
# (it replaces whatever PL app is loaded now; `sudo xmutil unloadapp` undoes it).
set -u
cd "$(dirname "$0")"
APP="${1:-}"
if [ -z "$APP" ]; then
  set -- *.bit.bin
  if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "!! expected exactly one <app>.bit.bin in $(pwd); pass the app name: bash install_on_board.sh <app>"; exit 1
  fi
  APP="${1%.bit.bin}"
fi
for f in "$APP.bit.bin" "$APP.dtbo" shell.json; do
  [ -f "$f" ] || { echo "!! missing $f in $(pwd)"; exit 1; }
done
command -v xmutil >/dev/null || { echo "!! xmutil is not installed on this board image"; exit 1; }
sudo mkdir -p "/lib/firmware/xilinx/$APP"
sudo cp -f "$APP.bit.bin" "$APP.dtbo" shell.json "/lib/firmware/xilinx/$APP/"
echo "== apps before"; sudo xmutil listapps
sudo xmutil unloadapp >/dev/null 2>&1 || true
if ! sudo xmutil loadapp "$APP"; then
  echo "== loadapp failed once; restarting dfx-mgr so it rescans /lib/firmware/xilinx"
  sudo systemctl restart dfx-mgr; sleep 3
  sudo xmutil loadapp "$APP" || { echo "!! could not load $APP (see: sudo journalctl -u dfx-mgr -n 50)"; exit 1; }
fi
echo "== apps after"; sudo xmutil listapps
echo "fpga state: $(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null)"
echo "INSTALL_DONE -> now run:  sudo python3 pwm_test.py"
