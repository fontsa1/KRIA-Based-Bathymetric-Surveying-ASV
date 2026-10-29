# WSL Vivado/Vitis PowerShell Commands

_Last updated October 14, 2026 · Vivado/Vitis 2023.1 on Windows 11 + WSL 2 (Ubuntu 22.04)_

## Before you start

Type these in a normal (non-admin) PowerShell tab in Windows Terminal unless a row says otherwise. Plain `wsl` opens **Ubuntu-22.04**, your default distro.

- **Paths** assume the Linux user `xbox_` (home folder `/home/xbox_`). On your own machine, swap in your Linux username, and your own folders for the `D:\School\Senior Design` paths.
- **Keep projects in the Linux home** (for example `~/kr260`), not on `/mnt/c` or `/mnt/d`. Windows drives are much slower from Linux and can break builds.
- **`bash -ic`** in the launch commands loads `~/.bashrc`, which puts the 2023.1 tools on the PATH.
- **A GUI launched from PowerShell keeps that window busy** until you close the GUI. Use the hidden launch in the next section to get the prompt back.

## Open Ubuntu and launch the tools

Vivado opens straight from PowerShell. The Vitis IDE closes as soon as a one-line `wsl` command finishes, so start Vitis (and Vitis HLS) from an Ubuntu shell and leave that shell open while you work. Inside Ubuntu (`wsl ~`) you can type `vivado`, `vitis`, `vitis_hls`, `v++` or `xsct`.

| Task | PowerShell command |
| --- | --- |
| Open an Ubuntu shell in your Linux home | `wsl ~` |
| Open Vivado | `wsl --cd ~ -e bash -ic vivado` |
| Open Vivado in a project folder (its log files land there too) | `wsl --cd /home/xbox_/kr260 -e bash -ic vivado` |
| Open the Vitis Classic IDE (the one the tutorial uses) | `wsl ~`, then `vitis` |
| Open the new Vitis Unified IDE | `wsl ~`, then `vitis -new` |
| Open Vitis HLS | `wsl ~`, then `vitis_hls` |
| Open Vivado and get the PowerShell prompt back | `Start-Process wsl -ArgumentList '--cd ~ -e bash -ic vivado' -WindowStyle Hidden` |

The **Ubuntu-22.04** entry in Windows Terminal's new-tab dropdown opens the same shell as `wsl ~`.

## Batch jobs and quick checks

Batch runs need no GUI. `--cd` takes `~` or a full Linux path that starts with `/`.

| Task | PowerShell command |
| --- | --- |
| Run the tutorial's Tcl script (it must already be in `~/kr260`) | `wsl --cd /home/xbox_/kr260 -e bash -ic "vivado -mode batch -source amd_contest_design.tcl"` |
| Open the Vivado Tcl shell | `wsl --cd ~ -e bash -ic "vivado -mode tcl"` |
| Run an xsct (Vitis command-line) script | `wsl --cd ~ -e bash -ic "xsct my_script.tcl"` |
| Check the Vivado version | `wsl -e bash -ic "vivado -version"` |
| Check the v++ version | `wsl -e bash -ic "v++ --version"` |
| Run any other Linux command with the tools loaded | `wsl -e bash -ic "<command>"` |

## Files between Windows and Linux

Windows reaches your Linux home at `\\wsl.localhost\Ubuntu-22.04\home\xbox_`, so normal PowerShell copy commands work.

| Task | PowerShell command |
| --- | --- |
| Open your Linux home in File Explorer | `explorer.exe \\wsl.localhost\Ubuntu-22.04\home\xbox_` |
| Copy a download into `~/kr260` | `Copy-Item "$env:USERPROFILE\Downloads\DPUCZDX8G.tar.gz" "\\wsl.localhost\Ubuntu-22.04\home\xbox_\kr260\"` |
| Copy the tutorial Tcl into `~/kr260` | `Copy-Item "D:\School\Senior Design\amd_contest_design.tcl" "\\wsl.localhost\Ubuntu-22.04\home\xbox_\kr260\"` |
| Copy a build output to your Senior Design folder | `Copy-Item "\\wsl.localhost\Ubuntu-22.04\home\xbox_\kr260\design.xsa" "D:\School\Senior Design\"` |
| Show the Windows path of a Linux folder | `wsl wslpath -w /home/xbox_/kr260` |

Inside Ubuntu, your Windows drives are `/mnt/c` and `/mnt/d`, and `explorer.exe .` opens the current Linux folder in File Explorer.

## KR260 USB JTAG and serial console

The KR260's micro-USB port **J4** carries both JTAG and the UART through one FTDI chip (USB ID `0403:6011`). usbipd passes that chip into Ubuntu, and **while it's attached, Windows can't use it**.

If you have the `_wsl_setup` scripts from the install, this one finds the board, shares it (one admin prompt the first time), attaches it and checks JTAG:

`powershell -NoProfile -ExecutionPolicy Bypass -File "D:\School\Senior Design\_wsl_setup\step8_usb_jtag.ps1"`

| Task | PowerShell command |
| --- | --- |
| Find the board's BUSID (the row showing `0403:6011`) | `usbipd list` |
| Share it with WSL. Admin PowerShell, needed once per USB port | `usbipd bind --busid <BUSID>` |
| Attach it to Ubuntu (after every plug-in or WSL restart) | `usbipd attach --wsl --busid <BUSID>` |
| Keep re-attaching automatically (leave the window open) | `usbipd attach --wsl --busid <BUSID> --auto-attach` |
| Give the board back to Windows | `usbipd detach --busid <BUSID>` |
| List the board's serial ports in Ubuntu | `wsl -e bash -c "ls /dev/ttyUSB*"` |
| Open the KR260 Linux console (115200 baud; quit with Ctrl+A, K, Y) | `wsl -e screen /dev/ttyUSB1 115200` |

After attaching, open Vivado, then **Open Hardware Manager → Open Target → Auto Connect**. You should see `xck26` and `arm_dap`. If `ttyUSB1` shows no console text, try `ttyUSB0`, `ttyUSB2` or `ttyUSB3`.

## PetaLinux and Vitis AI

PetaLinux runs from an Ubuntu shell. Vitis AI runs inside Docker, which starts with Ubuntu on its own.

| Task | PowerShell command |
| --- | --- |
| PetaLinux: open Ubuntu, then type `plnx` before any `petalinux-*` command | `wsl ~` |
| Vitis AI GPU container (uses the GTX 1050) | `wsl --cd /home/xbox_/Vitis-AI -e bash -ic "./docker_run.sh xilinx/vitis-ai-pytorch-gpu:latest"` |
| Vitis AI CPU container | `wsl --cd /home/xbox_/Vitis-AI -e bash -ic "./docker_run.sh xilinx/vitis-ai-pytorch-cpu:latest"` |
| List the Docker images | `wsl -e docker images` |
| Confirm the GPU is visible | `wsl -e nvidia-smi` |

Inside a container, run `conda activate vitis-ai-pytorch` first. Your `~/Vitis-AI` folder appears there as `/workspace`, so keep YOLO model files in it. The first launch asks you to accept AMD's terms.

## Manage WSL and fix common problems

`wsl --shutdown` is the usual fix, but it **closes every Linux app, container and build at once**, so save your Vivado work first.

| Task | PowerShell command |
| --- | --- |
| See which distros exist and which are running | `wsl -l -v` |
| Stop Ubuntu completely and free its RAM | `wsl --shutdown` |
| Update WSL (run `wsl --shutdown` afterwards) | `wsl --update` |
| Change the RAM/swap limits (now 12 GB / 16 GB; `wsl --shutdown` after saving) | `notepad $env:USERPROFILE\.wslconfig` |
| Check memory inside Ubuntu | `wsl -e free -h` |
| Check free disk space inside Ubuntu | `wsl -e df -h /` |
| Silence the "To run a command as administrator" message (once) | `wsl -e bash -c "touch ~/.sudo_as_admin_successful"` |

**Quick fixes**

- **A Vivado or Vitis window doesn't appear or freezes:** close it, run `wsl --shutdown`, wait about 10 seconds and launch it again.
- **File → New → Platform Project does nothing in the Vitis Classic IDE:** Ubuntu is missing the icon theme that wizard needs. Run `wsl -u root bash -c "apt-get update && apt-get install -y adwaita-icon-theme-full librsvg2-common"`, then restart Vitis.
- **`vivado: command not found`:** the command is missing `bash -ic`, or it ran in the plain "Ubuntu" distro. `wsl -l -v` should show a `*` next to Ubuntu-22.04.
- **A build runs out of memory:** close large Windows apps such as browsers. WSL can use up to 12 GB of RAM plus 16 GB of swap.
- **Hardware Manager can't see the KR260 after a replug or a WSL restart:** run the `usbipd attach` command again.
