# KR260 DPU + 2-PWM design

This is the KR260 DPU tutorial design (DPUCZDX8G, built by Vitis) with two AXI Timer PWM outputs and a GPIO enable added on PMOD1 for the ASV motor drivers.
Vitis regenerates its Vivado project on every hardware build. So git stores the build inputs plus a patch script, and the finished files go on a GitHub Release.

| Port | Driven by | Address | KR260 pin |
| --- | --- | --- | --- |
| `PWM_0` | `axi_timer_1/pwm0` | `0xA003_0000` | H12, PMOD1 upper row, pin 1 |
| `PWM_1` | `axi_timer_0/pwm0` | `0xA002_0000` | E10, PMOD1 upper row, pin 2 |
| `gpio_rtl_tri_o[0]` (enable) | `axi_gpio_0` | `0xA001_0000` | B10, PMOD1 lower row, pin 1 |

All three use LVCMOS33. They sit on `M_AXI_HPM0_FPD` and run from `clk_wiz_0/clk_out4` at 300 MHz.

## Contents

| Path | What it is |
| --- | --- |
| `vivado/add_pwm_gpio.tcl` | Adds the PWM/GPIO blocks, their addresses and pins to the Vivado project that Vitis generates |
| `vivado/kr260_pwm_pins.xdc` | Pin constraints used by the patch |
| `vitis/` | Copies of the Vitis workspace settings (`dpu_conf.vh`, `prj_config`, project files). Reference only: they contain the original laptop's paths. |
| `platform/` | The platform's Vivado project saved as Tcl, if it was exported. Rebuild it with its `rebuild.tcl` and the `xsa` option. |
| `board/package_app.sh` | Turns the implemented project into a KR260 app folder (`.bit.bin`, `.dtbo`, `shell.json`) |
| `board/install_on_board.sh`, `board/pwm_test.py` | Run on the KR260 to load the app with `xmutil` and drive the PWMs |
| `export_dpu_pwm.sh` | Refreshes `vitis/` (and `platform/`) and fills the Release folder |

## Use the prebuilt files

1. Download `kr260_pwm_app.tar.gz` from the repo's Releases page.
2. Copy it to the board and load it. You type the board's password.

   ```bash
   scp kr260_pwm_app.tar.gz ubuntu@<board-ip>:~/
   ssh ubuntu@<board-ip>
   tar xzf kr260_pwm_app.tar.gz && cd kr260_pwm && bash install_on_board.sh
   sudo python3 pwm_test.py --freq 1000 --duty0 25 --duty1 75
   ```

## Rebuild from source

1. **Platform XSA.** Use `amd_contest_design.xsa` from the Release, or rebuild `platform/` with its `rebuild.tcl` and the `xsa` option.
2. **Vitis Classic 2023.1.** Follow the KR260 DPU tutorial: create a platform project from that XSA, then a DPU application with one DPU core.
   Copy the settings from `vitis/` (`dpu_conf.vh`, `prj_config`) and build the `*_system_hw_link` project for Hardware.
3. **Patch.** Open `<workspace>/<app>_system_hw_link/Hardware/dpu.build/link/vivado/vpl/prj/prj.xpr` in Vivado.
   Choose **Tools > Run Tcl Script...**, pick `vivado/add_pwm_gpio.tcl`, then click **Generate Bitstream**.
   In batch mode: `vivado -mode batch -source add_pwm_gpio.tcl -tclargs <prj.xpr> build`.
   Any later Vitis rebuild of the hw_link project removes the patch, so repeat this step after one.
4. **Package.** In Ubuntu (WSL), run `bash board/package_app.sh`. The app lands in `~/kr260/kr260_pwm/`.

## Publish a new version

1. In Ubuntu (WSL), run `bash export_dpu_pwm.sh`. It stops if the board package is older than the bitstream.
2. Commit and push `SoC files/kr260_dpu_pwm/`.
3. Create a Release with a new tag (`kr260-dpu-pwm-v2` and so on), following `../README.md`.
   Attach every file from `D:\School\Senior Design\release_kr260_dpu_pwm\` and paste `RELEASE_NOTES.md` as the description.
