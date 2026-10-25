# testme - a testing pico framework for Tcl
# https://github.com/okhlybov/testme


# The throughput benchmark of the trivial units: every unit gets a fresh
# interpreter, so the measurement exposes the per-unit setup cost paid for the
# isolation, amortized across the pool workers in the parallel mode.
# The environment configuration repeats the run under a bloated ::env table
# (the snapshot cost must not depend on its size), the subprocess one runs
# units spending their time in external programs.
# usage: tclsh bench.tcl ?units? ?subprocess-units?


set root [file normalize [file join [file dirname [info script]] ..]]
set tclsh [info nameofexecutable]

set units 500
if {[llength $::argv] > 0} {set units [lindex $::argv 0]}
set subs 100
if {[llength $::argv] > 1} {set subs [lindex $::argv 1]}
if {![string is integer -strict $units] || $units <= 0} {error "invalid unit count: $units"}
if {![string is integer -strict $subs] || $subs <= 0} {error "invalid subprocess unit count: $subs"}


# Runs a suite reporting the elapsed wall time in milliseconds; the quiet mode
# keeps the TAP stream out of the way, the exit code guards against breakage
proc timed {cmd} {
  set t0 [clock milliseconds]
  set rc [catch {exec {*}$cmd -q 2>@1} out]
  set ms [expr {[clock milliseconds] - $t0}]
  if {$rc} {
    puts stderr "bench: the measured run failed: $out"
    exit 1
  }
  return $ms
}


# Builds a suite of $n units with the given body
proc MakeSuite {path root body n} {
  set f [open $path w]
  try {
    puts $f [list tcl::tm::add $root]
    puts $f {package require testme}
    for {set i 0} {$i < $n} {incr i} {puts $f [list unit $body]}
  } finally {
    close $f
  }
}


set dir {}
foreach var {TMPDIR TMP} {
  if {[info exists ::env($var)]} {
    set candidate [file join $::env($var) testme-bench.[pid].[clock microseconds]]
    if {![catch {file mkdir $candidate}]} {set dir $candidate; break}
  }
}
if {$dir eq {}} {
  set dir [file join /tmp testme-bench.[pid].[clock microseconds]]
  file mkdir $dir
}

try {

  set suite [file join $dir test.tcl]
  MakeSuite $suite $root {expr {42}} $units

  set msParallel [timed [list $tclsh $suite]]
  set msSerial [timed [list $tclsh $suite -s]]

  for {set i 0} {$i < 200} {incr i} {set ::env(BENCH_VAR_$i) [string repeat x 64]}
  set msEnvParallel [timed [list $tclsh $suite]]
  set msEnvSerial [timed [list $tclsh $suite -s]]
  for {set i 0} {$i < 200} {incr i} {unset -nocomplain ::env(BENCH_VAR_$i)}

  if {$::tcl_platform(platform) eq {windows}} {
    set nop {exec $::env(COMSPEC) /c exit 0}
  } else {
    set nop {exec true}
  }
  set subsuite [file join $dir sub.tcl]
  MakeSuite $subsuite $root $nop $subs
  set msSubs [timed [list $tclsh $subsuite]]

  puts [format "%d trivial units: %d ms parallel, %d ms serial" $units $msParallel $msSerial]
  puts [format "%d trivial units under 200 extra environment variables: %d ms parallel, %d ms serial" $units $msEnvParallel $msEnvSerial]
  puts [format "%d subprocess units: %d ms parallel" $subs $msSubs]

} finally {
  file delete -force $dir
}
