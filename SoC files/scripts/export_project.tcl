# export_project.tcl -- save a Vivado project as small, git-friendly text files.
#
# Writes everything needed to recreate the project into one folder, by default
# "SoC files/<project name>/" (next to this scripts/ folder):
#   project_info.tcl   part, board, top module, file lists, run strategies, platform settings
#   bd/<name>.tcl      one script per block design (write_bd_tcl -include_layout)
#   hdl/  sim/         your HDL and testbenches (files Vivado generates for IP / block designs are skipped)
#   constraints/       XDC files
#   ip/                IP customized outside a block design (.xci)
#   ip_repo/<name>/    copies of custom IP repositories (each up to 25 MB)
#   rebuild.tcl        run this on the other computer to recreate the project
# Build results (.bit, .bin, .xsa, .xclbin ...) are NOT exported: share those on a GitHub Release.
#
# Vivado GUI: open the project, then Tools > Run Tcl Script... and pick this file.
#   To export somewhere else, first type in the Tcl Console:   set export_dest {D:/path/to/folder}
# Batch:  vivado -mode batch -source export_project.tcl -tclargs <project.xpr> [<folder>] [force]
#
# Safe to re-run: a file is only rewritten when it changed, nothing is ever deleted, and a file in
# the folder that is NEWER than your project's copy and different (for example one you just pulled
# from GitHub) is kept and reported instead of overwritten. To overwrite anyway add "force", or
# type  set export_force 1  in the Tcl Console before running the script.
# Both computers need the same Vivado version (2023.1): block-design scripts only load in the
# version that wrote them.

namespace eval ::xport {
  variable script_dir [file dirname [file normalize [info script]]]
}

proc ::xport::say  {m} { puts "EXPORT: $m" }
proc ::xport::warn {m} { variable warnings; lappend warnings $m; puts "EXPORT WARNING: $m" }
proc ::xport::fail {m} { error "EXPORT FAILED: $m" }
proc ::xport::prop {obj name} {
  set v ""
  catch {set v [get_property $name $obj]}
  return $v
}

proc ::xport::same_part {a b} {
  if {$::tcl_platform(platform) eq "windows"} { return [string equal -nocase $a $b] }
  return [string equal $a $b]
}
proc ::xport::same_path {a b} { return [same_part [file normalize $a] [file normalize $b]] }

# relative path of $path inside directory $dir ("" when it is not inside)
proc ::xport::rel_inside {path dir} {
  set p [file split [file normalize $path]]
  set d [file split [file normalize $dir]]
  set n [llength $d]
  if {[llength $p] <= $n} { return "" }
  for {set i 0} {$i < $n} {incr i} {
    if {![same_part [lindex $p $i] [lindex $d $i]]} { return "" }
  }
  return [join [lrange $p $n end] /]
}
proc ::xport::under_any {path dirs} {
  foreach d $dirs {
    if {[rel_inside $path $d] ne ""} { return 1 }
  }
  return 0
}
# $target written relative to directory $from (absolute when it is on another drive)
proc ::xport::relpath {target from} {
  set t [file split [file normalize $target]]
  set f [file split [file normalize $from]]
  set i 0
  while {$i < [llength $t] && $i < [llength $f] && [same_part [lindex $t $i] [lindex $f $i]]} { incr i }
  if {$i == 0} { return [file normalize $target] }
  set up {}
  for {set j $i} {$j < [llength $f]} {incr j} { lappend up .. }
  return [join [concat $up [lrange $t $i end]] /]
}
proc ::xport::tmpdir {} {
  foreach v {TMPDIR TEMP TMP} {
    if {[info exists ::env($v)] && [file isdirectory $::env($v)]} { return $::env($v) }
  }
  if {[file isdirectory /tmp]} { return /tmp }
  return [pwd]
}
proc ::xport::slurp {f} {
  set fh [open $f r]
  fconfigure $fh -translation binary
  set data [read $fh]
  close $fh
  return [string map [list "\r\n" "\n"] $data]
}
proc ::xport::list_dir {dir type} {
  if {![file isdirectory $dir]} { return {} }
  set out {}
  foreach f [concat [glob -nocomplain -directory $dir -types $type *] \
                    [glob -nocomplain -directory $dir -types [list $type hidden] *]] {
    if {[file tail $f] in {. ..}} continue
    lappend out $f
  }
  return [lsort -unique $out]
}
proc ::xport::files_under {dir} {
  set out [list_dir $dir f]
  foreach d [list_dir $dir d] {
    if {[file type $d] ne "link"} { lappend out {*}[files_under $d] }
  }
  return $out
}
proc ::xport::junk {name} {
  foreach pat {.Xil .git *.cache *.runs *.gen *.hw *.sim *.ip_user_files *.jou *.log *.str *.backup.*} {
    if {[string match -nocase $pat $name]} { return 1 }
  }
  return 0
}
proc ::xport::tree_size {dir} {
  set s 0
  foreach f [list_dir $dir f] { if {![junk [file tail $f]]} { incr s [file size $f] } }
  foreach d [list_dir $dir d] {
    if {![junk [file tail $d]] && [file type $d] ne "link"} { incr s [tree_size $d] }
  }
  return $s
}

# Copy $src to $dst.  Returns new | updated | same | kept.
# kept = $dst is different AND newer than $ref (default: the time of $src), so it is not overwritten.
proc ::xport::put {src dst {ref ""}} {
  variable force
  variable counts
  if {[same_path $src $dst]} {
    set st same
  } elseif {![file exists $dst]} {
    file mkdir [file dirname $dst]
    file copy -force $src $dst
    set st new
  } elseif {[slurp $src] eq [slurp $dst]} {
    set st same
  } else {
    if {$ref eq ""} { set ref [file mtime $src] }
    if {!$force && [file mtime $dst] > $ref + 2} {
      set st kept
    } else {
      file copy -force $src $dst
      set st updated
    }
  }
  dict incr counts $st
  return $st
}
proc ::xport::copy_tree {src dst} {
  foreach f [list_dir $src f] {
    if {[junk [file tail $f]]} continue
    set to [file join $dst [file tail $f]]
    if {[put $f $to] eq "kept"} { warn "[file tail $to] in $dst is newer than the original -- not overwritten" }
  }
  foreach d [list_dir $src d] {
    if {[junk [file tail $d]] || [file type $d] eq "link"} continue
    copy_tree $d [file join $dst [file tail $d]]
  }
}

# Where a project file belongs inside $dest.  Returns {relative-path copy-needed}:
#   a file that already lives in $dest stays there (it was added straight from the repo);
#   a file imported from somewhere in $dest goes back to that spot; anything else -> <category>/<name>
proc ::xport::place {fobj dest category} {
  variable claimed
  variable pdir
  variable pname
  set fn [file normalize $fobj]
  set rel ""
  if {[rel_inside $fn [file join $pdir $pname.srcs]] eq ""} { set rel [rel_inside $fn $dest] }
  set copy 0
  if {$rel eq ""} {
    set copy 1
    set from [prop $fobj IMPORTED_FROM]
    if {$from ne ""} { set rel [rel_inside [file normalize [file join $pdir $from]] $dest] }
    if {$rel eq ""} {
      set rel $category/[file tail $fn]
      if {[dict exists $claimed $rel] && ![same_path [dict get $claimed $rel] $fn]} {
        set rel $category/[file tail [file dirname $fn]]/[file tail $fn]
      }
    }
  }
  dict set claimed $rel $fn
  return [list $rel $copy]
}
proc ::xport::export_file {fobj dest category} {
  lassign [place $fobj $dest $category] rel copy
  if {$copy && [put [file normalize $fobj] [file join $dest $rel]] eq "kept"} {
    warn "$rel was NOT overwritten: the copy in the folder is newer than your project's copy and different.\
          If you pulled changes, rebuild from the repo to get them; to overwrite anyway re-run with force."
  }
  return $rel
}

proc ::xport::read_info {f} {
  set d [dict create]
  set fh [open $f r]
  while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} continue
    if {[catch {llength $line} n] || $n != 3 || [lindex $line 0] ne "set"} continue
    if {[regexp {^design\((.+)\)$} [lindex $line 1] -> key]} { dict set d $key [lindex $line 2] }
  }
  close $fh
  return $d
}

proc ::xport::write_text {path lines} {
  set fh [open $path w]
  fconfigure $fh -translation lf
  foreach l $lines { puts $fh $l }
  close $fh
}

proc ::xport::main {} {
  variable script_dir
  variable warnings {}
  variable force 0
  variable counts [dict create new 0 updated 0 same 0 kept 0]
  variable claimed [dict create]
  variable pdir
  variable pname

  # ---- arguments
  set xpr ""
  set dest ""
  set args {}
  if {[info exists ::argv]} { set args $::argv }
  foreach a $args {
    if {[string equal -nocase $a force]} {
      set force 1
    } elseif {[string match -nocase *.xpr $a]} {
      set xpr $a
    } elseif {$dest eq ""} {
      set dest $a
    }
  }
  if {[info exists ::export_dest]} { set dest $::export_dest; unset ::export_dest }
  if {[info exists ::export_force]} { set force [string is true -strict $::export_force]; unset ::export_force }

  # ---- project
  if {[current_project -quiet] eq ""} {
    if {$xpr eq ""} { fail "no project is open. Open your project first (batch mode: -tclargs <project.xpr>)." }
    say "opening $xpr"
    open_project $xpr
  }
  set proj  [current_project]
  set pname [get_property NAME $proj]
  set pdir  [file normalize [get_property DIRECTORY $proj]]
  set xprf  [file join $pdir $pname.xpr]
  if {[string match */vivado/vpl/prj $pdir]} {
    fail "$pdir was generated by Vitis (v++) and is rewritten on every Vitis build, so it can't be shared\
          this way. For the DPU + PWM design use 'SoC files/kr260_dpu_pwm/export_dpu_pwm.sh' instead."
  }
  if {$dest eq ""} { set dest [file join $script_dir .. $pname] }
  set dest [file normalize $dest]
  if {[same_path $dest $script_dir] || [same_path $dest [file dirname $script_dir]] || [same_path $dest $pdir]} {
    fail "won't export into $dest -- give the design a folder of its own (set export_dest {...})."
  }
  set info_file [file join $dest project_info.tcl]
  if {[file exists $info_file]} {
    set old [read_info $info_file]
    if {[dict exists $old name] && [dict get $old name] ne $pname} {
      fail "$dest already holds project '[dict get $old name]', not '$pname'. Export somewhere else (set export_dest {...})."
    }
  }
  say "project '$pname'  ($xprf)"
  say "exporting to      $dest"
  if {$force} { say "force: newer files in the folder will be overwritten" }
  file mkdir $dest

  # folders whose contents Vivado generates (never exported)
  set gen_dirs {}
  foreach sub {gen ip_user_files cache runs hw sim} { lappend gen_dirs [file join $pdir $pname.$sub] }
  foreach ip [get_ips -quiet] {
    set d [prop $ip IP_DIR]
    if {$d ne ""} { lappend gen_dirs [file normalize $d] }
  }

  # ---- block designs (BDs nested inside IP are skipped)
  set bd_objs {}
  foreach f [get_files -quiet -of_objects [get_filesets sources_1] -filter {NAME =~ "*.bd"}] {
    set fn [file normalize $f]
    if {[string match */bd/*/ip/* $fn]} continue
    lappend bd_objs $f
    lappend gen_dirs [file dirname $fn]
  }

  set all_rel {}
  set seen [dict create]

  # ---- design sources
  set hdl {}
  set gen_wrappers {}
  foreach f [get_files -quiet -of_objects [get_filesets sources_1]] {
    set fn [file normalize $f]
    if {[dict exists $seen $fn]} continue
    dict set seen $fn 1
    if {[string tolower [file extension $fn]] in {.bd .xci .xcix}} continue
    if {[under_any $fn $gen_dirs]} {
      foreach b $bd_objs {
        set bn [file rootname [file tail $b]]
        if {[string match -nocase ${bn}_wrapper.* [file tail $fn]]} { lappend gen_wrappers $bn }
      }
      continue
    }
    if {![file exists $fn]} { warn "[file tail $fn] is in the project but missing on disk -- skipped"; continue }
    if {[file size $fn] > 25*1024*1024} { warn "[file tail $fn] is over 25 MB -- not exported (share it on a Release)"; continue }
    set rel [export_file $f $dest hdl]
    lappend hdl [list $rel [prop $f FILE_TYPE] [prop $f LIBRARY]]
    lappend all_rel $rel
  }
  set wrappers {}
  foreach b [lsort -unique $gen_wrappers] {
    set custom 0
    foreach e $hdl {
      if {[string match -nocase ${b}_wrapper.* [file tail [lindex $e 0]]]} { set custom 1 }
    }
    if {!$custom} { lappend wrappers $b }
  }

  # ---- block designs -> bd/<name>.tcl
  set bds {}
  set bd_props {}
  foreach f $bd_objs {
    set fn [file normalize $f]
    set b [file rootname [file tail $fn]]
    lappend bds $b
    set opened 0
    if {[get_bd_designs -quiet $b] eq ""} { open_bd_design $fn; set opened 1 }
    current_bd_design [get_bd_designs $b]
    set tmp [file join [tmpdir] export_${pname}_$b.tcl]
    if {[catch {write_bd_tcl -force -include_layout $tmp} e]} {
      warn "block design $b: layout not saved ($e)"
      write_bd_tcl -force $tmp
    }
    if {$opened} { catch {close_bd_design [get_bd_designs $b]} }
    set rel bd/$b.tcl
    set st [put $tmp [file join $dest $rel] [file mtime $fn]]
    file delete -force $tmp
    if {$st eq "kept"} {
      warn "$rel was NOT overwritten: the copy in the folder is newer than your block design and different.\
            If you pulled changes, rebuild from the repo first. If you have unsaved block-design edits,\
            save them (Ctrl+S) and export again. To overwrite anyway re-run with force."
    }
    lappend all_rel $rel
    set v [prop $f SYNTH_CHECKPOINT_MODE]
    if {$v ne ""} { lappend bd_props [list $b SYNTH_CHECKPOINT_MODE $v] }
  }

  # ---- simulation sources (active simulation set)
  set sim {}
  set sim_top ""
  set simset [current_fileset -simset -quiet]
  if {$simset ne ""} {
    set sim_top [prop $simset TOP]
    foreach f [get_files -quiet -of_objects $simset] {
      set fn [file normalize $f]
      if {[dict exists $seen $fn]} continue
      dict set seen $fn 1
      if {[string tolower [file extension $fn]] in {.bd .xci .xcix}} continue
      if {[under_any $fn $gen_dirs] || ![file exists $fn]} continue
      if {[file size $fn] > 25*1024*1024} { warn "[file tail $fn] is over 25 MB -- not exported"; continue }
      set rel [export_file $f $dest sim]
      lappend sim [list $rel [prop $f FILE_TYPE] [prop $f LIBRARY]]
      lappend all_rel $rel
    }
  }

  # ---- constraints (active constraint set)
  set xdc {}
  set target ""
  set cname constrs_1
  set cset [current_fileset -constrset -quiet]
  if {$cset ne ""} {
    set cname [get_property NAME $cset]
    set tgt [prop $cset TARGET_CONSTRS_FILE]
    if {$tgt ne ""} { set tgt [file normalize $tgt] }
    foreach f [get_files -quiet -of_objects $cset] {
      set fn [file normalize $f]
      if {[under_any $fn $gen_dirs] || ![file exists $fn]} continue
      set rel [export_file $f $dest constraints]
      set row [list $rel]
      foreach p {IS_ENABLED USED_IN_SYNTHESIS USED_IN_IMPLEMENTATION PROCESSING_ORDER} { lappend row [prop $f $p] }
      lappend xdc $row
      lappend all_rel $rel
      if {$tgt ne "" && [same_path $tgt $fn]} { set target $rel }
    }
  }
  foreach cs [get_filesets -quiet -filter {FILESET_TYPE == "Constrs"}] {
    if {[get_property NAME $cs] eq $cname} continue
    if {[llength [get_files -quiet -of_objects $cs]]} {
      warn "constraint set [get_property NAME $cs] is not the active one and was not exported"
    }
  }

  # ---- IP customized outside block designs
  set ip_list {}
  if {[catch {set ips [get_ips -quiet -exclude_bd_ips]}]} {
    set ips {}
    foreach ip [get_ips -quiet] {
      if {![string match */bd/* [prop $ip IP_FILE]]} { lappend ips $ip }
    }
  }
  foreach ip $ips {
    set xf [prop $ip IP_FILE]
    if {$xf eq "" || ![file exists $xf]} { warn "IP $ip: .xci file not found -- skipped"; continue }
    if {[file size $xf] > 25*1024*1024} { warn "IP $ip: [file tail $xf] is over 25 MB -- not exported"; continue }
    set fobj [lindex [get_files -quiet $xf] 0]
    if {$fobj eq ""} { set fobj $xf }
    set rel [export_file $fobj $dest ip]
    lappend ip_list $rel
    lappend all_rel $rel
  }

  # ---- custom IP repositories
  set repos {}
  set repos_ext {}
  foreach r [prop $proj IP_REPO_PATHS] {
    set r [file normalize [file join $pdir $r]]
    if {![file isdirectory $r]} { warn "IP repository $r does not exist -- skipped"; continue }
    set in [rel_inside $r $dest]
    if {$in ne ""} { lappend repos $in; continue }
    set size [tree_size $r]
    if {$size > 25*1024*1024} {
      warn "IP repository $r is [expr {$size / 1048576}] MB, too big to copy -- the other computer needs it at the same path"
      lappend repos_ext $r
      continue
    }
    set rel ip_repo/[file tail $r]
    copy_tree $r [file join $dest $rel]
    lappend repos $rel
  }

  # ---- project-level settings
  set plat {}
  foreach p [lsort [list_property $proj]] {
    if {![string match -nocase platform.* $p]} continue
    set v [prop $proj $p]
    if {$v ne ""} { lappend plat [string tolower $p] $v }
  }
  set fsprops {}
  foreach p {GENERIC VERILOG_DEFINE} {
    set v [prop [get_filesets sources_1] $p]
    if {$v ne ""} { lappend fsprops $p $v }
  }
  set inc [prop [get_filesets sources_1] INCLUDE_DIRS]
  if {$inc ne ""} { warn "sources_1 uses include directories ($inc) -- not exported" }
  foreach r {synth_1 impl_1} {
    set ro [get_runs -quiet $r]
    if {$ro eq ""} continue
    foreach p [list_property $ro] {
      if {[string match -nocase STEPS.*.TCL.PRE $p] || [string match -nocase STEPS.*.TCL.POST $p]} {
        set v [prop $ro $p]
        if {$v ne ""} { warn "run $r uses a hook script ($p = $v) -- it is not exported" }
      }
    }
  }

  set info [list \
    name               $pname \
    vivado_version     [version -short] \
    part               [prop $proj PART] \
    board_part         [prop $proj BOARD_PART] \
    board_connections  [prop $proj BOARD_CONNECTIONS] \
    target_language    [prop $proj TARGET_LANGUAGE] \
    simulator_language [prop $proj SIMULATOR_LANGUAGE] \
    default_lib        [prop $proj DEFAULT_LIB] \
    top                [prop [get_filesets sources_1] TOP] \
    bds                $bds \
    bd_props           $bd_props \
    wrappers           $wrappers \
    hdl                $hdl \
    ip                 $ip_list \
    ip_repos           $repos \
    ip_repos_external  $repos_ext \
    fileset_props      $fsprops \
    constrset          $cname \
    xdc                $xdc \
    target_xdc         $target \
    sim                $sim \
    sim_top            $sim_top \
    platform           $plat \
    synth_strategy     [prop [get_runs -quiet synth_1] STRATEGY] \
    impl_strategy      [prop [get_runs -quiet impl_1] STRATEGY] ]
  set lines [list \
    "# project_info.tcl -- written by export_project.tcl, read by rebuild_project.tcl." \
    "# Vivado project '$pname'. One setting per line."]
  foreach {k v} $info { lappend lines [list set design($k) [string map [list "\n" " " "\r" ""] $v]] }
  set tmp [file join [tmpdir] export_${pname}_project_info.tcl]
  write_text $tmp $lines
  set ref [clock seconds]
  if {[file exists $xprf]} { set ref [file mtime $xprf] }
  if {[put $tmp $info_file $ref] eq "kept"} {
    warn "project_info.tcl was NOT overwritten: the copy in the folder is newer than your project and different\
          (did you pull changes? rebuild from the repo first). To overwrite anyway re-run with force."
  }
  file delete -force $tmp

  # ---- rebuild.tcl launcher and a README for GitHub
  set rb [relpath [file join $script_dir rebuild_project.tcl] $dest]
  set tmp [file join [tmpdir] export_${pname}_rebuild.tcl]
  write_text $tmp [list \
    "# rebuild.tcl -- recreate the Vivado project '$pname' from this folder (written by export_project.tcl)." \
    "#   Vivado GUI, with no project open: Tools > Run Tcl Script... > pick this file." \
    "#     The project is created in ~/vivado_builds/$pname/ and opened." \
    "#   Batch: vivado -mode batch -source rebuild.tcl -tclargs \[<build folder>\] \[build\] \[xsa\] \[force\]" \
    "set ::rebuild_design_dir \[file dirname \[file normalize \[info script\]\]\]" \
    "source \[file join \$::rebuild_design_dir [list $rb]\]"]
  put $tmp [file join $dest rebuild.tcl] [clock seconds]
  file delete -force $tmp
  set readme [file join $dest README.md]
  if {![file exists $readme]} {
    write_text $readme [list \
      "# $pname" "" \
      "Vivado [version -short] project, saved as text with \`SoC files/scripts/export_project.tcl\`." "" \
      "- **Get it:** pull, then in Vivado (no project open) **Tools > Run Tcl Script...** > \`rebuild.tcl\` in this folder." \
      "  The project is created in \`~/vivado_builds/$pname/\`." \
      "- **Share your changes:** open the project, **Tools > Run Tcl Script...** > \`SoC files/scripts/export_project.tcl\`, then commit and push this folder." \
      "- **Bitstreams / XSAs:** on the repo's GitHub Releases page, not in git."]
    dict incr counts new
  }

  # ---- report
  set used [dict create project_info.tcl 1 rebuild.tcl 1 README.md 1]
  foreach r $all_rel { dict set used $r 1 }
  set stale {}
  foreach sub {bd hdl sim constraints ip} {
    foreach f [files_under [file join $dest $sub]] {
      set r [rel_inside $f $dest]
      if {![dict exists $used $r]} { lappend stale $r }
    }
  }
  foreach f [list_dir $dest f] {
    set t [file tail $f]
    if {![dict exists $used $t] && [string tolower [file extension $t]] in {.v .sv .vhd .vhdl .vh .svh .xdc .xci .tcl .bd}} {
      lappend stale $t
    }
  }
  say "done: [dict get $counts new] new, [dict get $counts updated] updated, [dict get $counts same] unchanged,\
       [dict get $counts kept] kept (newer copy already in the folder)"
  say "      [llength $bds] block design(s), [llength $hdl] source file(s), [llength $xdc] constraint file(s),\
       [llength $ip_list] IP, [llength $sim] simulation file(s)"
  if {[llength $stale]} { say "no longer used by the project (delete them if you don't need them): [join $stale {, }]" }
  if {[llength $warnings]} { say "[llength $warnings] warning(s) -- see the EXPORT WARNING lines above" }
  say "next: commit and push the folder '[file tail $dest]'. Bitstreams and XSAs go on a GitHub Release."
}

::xport::main
