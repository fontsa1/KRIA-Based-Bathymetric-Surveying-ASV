# rebuild_project.tcl -- recreate a Vivado project from a folder written by export_project.tcl.
#
# Usually started through the rebuild.tcl inside a design folder:
#   Vivado GUI, with no project open: Tools > Run Tcl Script... > pick "SoC files/<design>/rebuild.tcl"
#     -> the project is created in ~/vivado_builds/<design>/ (or <design>_2, _3 ... if that one exists)
#        and opened; then click Generate Bitstream as usual.
#   Batch:  vivado -mode batch -source "SoC files/<design>/rebuild.tcl" -tclargs [<build folder>] [build] [xsa] [force]
#   or:     vivado -mode batch -source rebuild_project.tcl -tclargs <design folder> [<build folder>] [build] [xsa] [force]
#     build : also run synthesis, implementation and write_bitstream
#     xsa   : also write <build folder>/<design>.xsa (pre-synthesis XSA for an extensible Vitis
#             platform; otherwise a fixed XSA with the bitstream, which implies build)
#     force : overwrite a project that already exists in <build folder>
# Needs the Vivado version the design was exported from, and the board files (e.g. KR260) installed.

namespace eval ::rebuild {
  variable script_dir [file dirname [file normalize [info script]]]
}

proc ::rebuild::say  {m} { puts "REBUILD: $m" }
proc ::rebuild::warn {m} { variable warnings; lappend warnings $m; puts "REBUILD WARNING: $m" }
proc ::rebuild::fail {m} { error "REBUILD FAILED: $m" }
proc ::rebuild::get {d k {def ""}} {
  if {[dict exists $d $k]} { return [dict get $d $k] }
  return $def
}
proc ::rebuild::read_info {f} {
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
proc ::rebuild::home {} {
  foreach v {HOME USERPROFILE} {
    if {[info exists ::env($v)] && $::env($v) ne ""} { return [file normalize $::env($v)] }
  }
  return [pwd]
}
proc ::rebuild::jobs {} {
  set n 4
  catch {
    if {$::tcl_platform(platform) eq "windows"} { set n $::env(NUMBER_OF_PROCESSORS) } else { set n [exec nproc] }
  }
  if {![string is integer -strict $n] || $n < 1} { set n 4 }
  return [expr {min($n, 6)}]
}
# import one file into fileset $fs; returns the project's file object
proc ::rebuild::import_one {fs f} {
  if {![file exists $f]} { fail "$f is listed in project_info.tcl but is missing" }
  set obj [lindex [import_files -fileset $fs -norecurse $f] 0]
  if {$obj eq ""} { set obj [lindex [get_files -quiet -of_objects [get_filesets $fs] */[file tail $f]] 0] }
  if {$obj eq ""} { fail "could not add [file tail $f] to the project" }
  return $obj
}
proc ::rebuild::set_props {obj pairs what} {
  foreach {p v} $pairs {
    if {$v eq ""} continue
    if {[catch {set_property $p $v $obj} e]} { warn "$what: could not set $p to '$v' ($e)" }
  }
}

proc ::rebuild::main {} {
  variable warnings {}
  set design_dir ""
  set build_dir ""
  set do_build 0
  set do_xsa 0
  set force 0
  if {[info exists ::rebuild_design_dir]} { set design_dir $::rebuild_design_dir; unset ::rebuild_design_dir }
  set args {}
  if {[info exists ::argv]} { set args $::argv }
  foreach a $args {
    switch -nocase -- $a {
      build   { set do_build 1 }
      xsa     { set do_xsa 1 }
      force   { set force 1 }
      default {
        if {$design_dir eq "" && [file exists [file join $a project_info.tcl]]} {
          set design_dir $a
        } elseif {$build_dir eq ""} {
          set build_dir $a
        } else {
          fail "don't know what to do with the argument '$a'"
        }
      }
    }
  }
  if {$design_dir eq ""} {
    fail "no design folder. Run the rebuild.tcl inside the design's folder, or pass the folder:\
          vivado -mode batch -source rebuild_project.tcl -tclargs <design folder>"
  }
  set design_dir [file normalize $design_dir]
  set info_file [file join $design_dir project_info.tcl]
  if {![file exists $info_file]} { fail "$info_file not found -- export the project with export_project.tcl first" }
  set d [read_info $info_file]
  set name [get $d name]
  set part [get $d part]
  if {$name eq "" || $part eq ""} { fail "$info_file has no project name or part" }
  set want [get $d vivado_version]
  set have [version -short]
  if {$want ne "" && [string first $want $have] < 0} {
    fail "'$name' was exported from Vivado $want but this is Vivado $have. Block-design scripts only load\
          in the Vivado version that wrote them, so use Vivado $want."
  }
  if {[current_project -quiet] ne ""} {
    fail "a project is open. Close it first (File > Close Project), then run this again."
  }

  # ---- where to build
  set auto [expr {$build_dir eq ""}]
  if {$auto} { set build_dir [file join [home] vivado_builds $name] }
  set build_dir [file normalize $build_dir]
  if {[file exists [file join $build_dir $name.xpr]] && !$force} {
    if {!$auto} { fail "$build_dir already holds $name.xpr. Pick another folder, or add 'force' to overwrite it." }
    set i 2
    while {[file exists [file join ${build_dir}_$i $name.xpr]]} { incr i }
    say "$build_dir already holds a project -- using ${build_dir}_$i"
    set build_dir ${build_dir}_$i
  }

  # ---- board files
  set bp [get $d board_part]
  if {$bp ne "" && [get_board_parts -quiet $bp] eq ""} {
    set base [join [lrange [split $bp :] 0 2] :]
    set alt [lindex [lsort -dictionary [get_board_parts -quiet $base:*]] end]
    if {$alt eq ""} {
      fail "the board files for $bp are not installed. In Vivado: Tools > Vivado Store... > Boards,\
            find the board (for example 'Kria KR260 Robotics Starter Kit'), click Install, then run this again."
    }
    warn "board $bp is not installed -- using $alt instead"
    set bp $alt
  }

  # ---- project
  say "creating '$name' in $build_dir"
  file mkdir $build_dir
  if {$force} {
    create_project -force $name $build_dir -part $part
  } else {
    create_project $name $build_dir -part $part
  }
  set proj [current_project]
  if {$bp ne ""} { set_property BOARD_PART $bp $proj }
  set_props $proj [list BOARD_CONNECTIONS [get $d board_connections] TARGET_LANGUAGE [get $d target_language] \
                        SIMULATOR_LANGUAGE [get $d simulator_language] DEFAULT_LIB [get $d default_lib]] project
  set_props $proj [get $d platform] "platform setting"

  # ---- custom IP repositories (before the block designs that use them)
  set repos {}
  foreach r [get $d ip_repos] { lappend repos [file normalize [file join $design_dir $r]] }
  foreach r [get $d ip_repos_external] {
    if {[file isdirectory $r]} { lappend repos $r } else { warn "custom IP repository $r is not on this computer" }
  }
  if {[llength $repos]} {
    set_property IP_REPO_PATHS $repos $proj
    update_ip_catalog -rebuild
  }

  # ---- design sources and stand-alone IP (module references in block designs need them first)
  foreach e [get $d hdl] {
    lassign $e rel ftype lib
    set obj [import_one sources_1 [file join $design_dir $rel]]
    set pairs [list FILE_TYPE $ftype]
    if {$lib ne "" && $lib ne "xil_defaultlib"} { lappend pairs LIBRARY $lib }
    set_props $obj $pairs $rel
  }
  set_props [get_filesets sources_1] [get $d fileset_props] sources_1
  foreach rel [get $d ip] { import_one sources_1 [file join $design_dir $rel] }
  catch {update_compile_order -fileset sources_1}

  # ---- block designs
  set wrappers [get $d wrappers]
  set bd_props [get $d bd_props]
  foreach b [get $d bds] {
    set t [file join $design_dir bd $b.tcl]
    if {![file exists $t]} { fail "bd/$b.tcl is missing from $design_dir" }
    say "creating block design $b"
    if {[catch {uplevel #0 [list source $t]} e]} {
      if {[string match -nocase *layout* $e] && [get_files -quiet $b.bd] ne ""} {
        warn "block design $b was created but its layout could not be restored ($e)"
      } else {
        fail "bd/$b.tcl stopped with an error: $e"
      }
    }
    set bdf [lindex [get_files -quiet $b.bd] 0]
    if {$bdf eq ""} {
      fail "bd/$b.tcl did not create block design $b. See the ERROR just above -- usually a different\
            Vivado version, or a custom IP repository that is missing."
    }
    if {[catch {validate_bd_design} e]} { warn "validate_bd_design reported problems in $b: $e" }
    save_bd_design
    foreach row $bd_props {
      lassign $row bn p v
      if {$bn eq $b} { set_props $bdf [list $p $v] "block design $b" }
    }
    if {$b in $wrappers} {
      set w [make_wrapper -files $bdf -top]
      if {$w eq "" || ![file exists $w]} {
        set pd [get_property DIRECTORY $proj]
        set w [lindex [glob -nocomplain [file join $pd $name.gen sources_1 bd $b hdl ${b}_wrapper.*] \
                                        [file join $pd $name.srcs sources_1 bd $b hdl ${b}_wrapper.*]] 0]
      }
      if {$w eq ""} { fail "could not create the HDL wrapper for $b" }
      add_files -norecurse -fileset sources_1 $w
    }
  }
  set top [get $d top]
  if {$top ne ""} { set_property TOP $top [get_filesets sources_1] }
  catch {update_compile_order -fileset sources_1}

  # ---- simulation sources
  foreach e [get $d sim] {
    lassign $e rel ftype lib
    set obj [import_one sim_1 [file join $design_dir $rel]]
    set pairs [list FILE_TYPE $ftype]
    if {$lib ne "" && $lib ne "xil_defaultlib"} { lappend pairs LIBRARY $lib }
    set_props $obj $pairs $rel
  }
  set st [get $d sim_top]
  if {$st ne ""} { set_props [get_filesets sim_1] [list TOP $st] sim_1 }

  # ---- constraints
  set cs [get $d constrset constrs_1]
  if {[get_filesets -quiet $cs] eq ""} { create_fileset -constrset $cs }
  if {$cs ne "constrs_1"} { catch {current_fileset -constrset [get_filesets $cs]} }
  set tgt [get $d target_xdc]
  foreach e [get $d xdc] {
    lassign $e rel en syn impl order
    set obj [import_one $cs [file join $design_dir $rel]]
    set_props $obj [list IS_ENABLED $en USED_IN_SYNTHESIS $syn USED_IN_IMPLEMENTATION $impl PROCESSING_ORDER $order] $rel
    if {$rel eq $tgt} { set_props [get_filesets $cs] [list TARGET_CONSTRS_FILE $obj] $cs }
  }

  # ---- run strategies
  foreach {r k} {synth_1 synth_strategy impl_1 impl_strategy} {
    set s [get $d $k]
    if {$s ne "" && [get_runs -quiet $r] ne ""} { set_props [get_runs $r] [list STRATEGY $s] $r }
  }
  say "project ready: [file join $build_dir $name.xpr]"

  # ---- optional build / XSA
  set ext 0
  catch {set ext [string is true -strict [get_property PLATFORM.EXTENSIBLE $proj]]}
  if {$do_build || ($do_xsa && !$ext)} {
    set n [jobs]
    say "building with $n jobs (synthesis, implementation, bitstream) -- this takes a while"
    launch_runs synth_1 -jobs $n
    wait_on_run synth_1
    set s [get_property STATUS [get_runs synth_1]]
    if {![string match -nocase *complete* $s]} { fail "synthesis did not finish: $s (see the synth_1 log)" }
    launch_runs impl_1 -to_step write_bitstream -jobs $n
    wait_on_run impl_1
    set s [get_property STATUS [get_runs impl_1]]
    if {![string match -nocase "*write_bitstream complete*" $s]} { fail "implementation did not finish: $s (see the impl_1 log)" }
    say "timing: WNS [get_property STATS.WNS [get_runs impl_1]] ns, WHS [get_property STATS.WHS [get_runs impl_1]] ns"
    say "bitstream: [lindex [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] *.bit]] 0]"
  }
  if {$do_xsa} {
    set xsa [file join $build_dir $name.xsa]
    if {$ext} {
      foreach b [get $d bds] { generate_target all [lindex [get_files $b.bd] 0] }
      write_hw_platform -force -file $xsa
    } else {
      open_run impl_1
      write_hw_platform -fixed -include_bit -force -file $xsa
    }
    say "wrote $xsa"
  }
  if {[llength $warnings]} { say "[llength $warnings] warning(s) -- see the REBUILD WARNING lines above" }
  say "done"
}

::rebuild::main
