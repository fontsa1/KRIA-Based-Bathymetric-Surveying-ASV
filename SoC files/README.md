# SoC files: sharing Vivado and Vitis designs through GitHub

Git holds the **recipe**: Tcl scripts, HDL, constraints and Vitis settings, all small text files.
A **GitHub Release** holds the **build results**: bitstreams, XSAs, xclbins and board packages.
GitHub warns about files over 50 MiB and rejects files over 100 MiB. A Release file can be up to 2 GiB.

| In git (small text) | On a Release (binaries you can rebuild) |
| --- | --- |
| `bd/*.tcl`, `hdl/`, `constraints/*.xdc`, `ip/*.xci`, `project_info.tcl`, Vitis `prj_config` / `dpu_conf.vh` | `.bit`, `.bit.bin`, `.xsa`, `.xclbin`, `.dtbo`, `.hwh`, packaged app `.tar.gz` |

Both laptops need two things:

- **Vivado/Vitis 2023.1.** A block-design script only loads in the Vivado version that wrote it.
- **The KR260 board files.** In Vivado: **Tools > Vivado Store... > Boards**.

## Folders

| Folder | Contents |
| --- | --- |
| `scripts/` | `export_project.tcl` turns any Vivado project into text, and `rebuild_project.tcl` turns that text back into a project |
| `kr260_dpu_pwm/` | The DPU + 2-PWM design that Vitis builds. It has its own flow, described in its README. |
| `<project>/` | One folder per exported Vivado project, for example `test1/`, written by `export_project.tcl` |

## Share a Vivado project you changed

1. Open the project in Vivado and save the block design.
2. Choose **Tools > Run Tcl Script...** and pick `SoC files/scripts/export_project.tcl`.
   It writes `SoC files/<project name>/` and reports what changed.
3. Commit and push that folder.
4. If your partner needs the bitstream without building it, attach it to a Release (see below).

## Get your partner's project

1. Pull.
2. In Vivado, with no project open, choose **Tools > Run Tcl Script...** and pick `SoC files/<project>/rebuild.tcl`.
   The project is created in `~/vivado_builds/<project>/` and opens. Then click **Generate Bitstream**.
   In batch mode, this also builds the bitstream:
   `vivado -mode batch -source "SoC files/<project>/rebuild.tcl" -tclargs build`
3. Work in that project, then export your changes (see above) so they reach git.

Work in this order: **pull, rebuild, edit, export, commit**. The export never deletes files. If a file in the folder is newer than your copy, for example one you just pulled, the export keeps it and tells you.

## Put bitstreams on a GitHub Release

1. Push your commits.
2. On the repo page, open **Releases** and click **Draft a new release**.
3. Under **Choose a tag**, type a new tag such as `kr260-dpu-pwm-v1` or `test1-v1`, and set the target to `main`.
4. Add a title and a short note on what changed. Drag the files into the attachment box.
5. Click **Publish release**. Your partner can then download the files from the Releases page.

Creating a Release needs write access to the repo.

## What the export does not cover

- **Vitis (v++) projects.** Vitis regenerates these, so share them the way `kr260_dpu_pwm/` does.
- **Run results, reports and ILA probe files (`.ltx`).** These come out of a build.
- **Run hook scripts, include directories and custom IP repositories over 25 MB.** The export warns when it skips one.
