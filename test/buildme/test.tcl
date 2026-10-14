package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]

# buildme sandbox creates a temporary copy of the suite stage and runs commands there
unit -name sandbox-basic [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list data.txt "sample input\n"]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme

unit -name run-sandbox {
  package require buildme
  buildme::sandbox {
    set cat \[expr {\$::tcl_platform(platform) eq \"windows\" ? \"type\" : \"cat\"}\]
    buildme::shell \"\$cat data.txt\"
    buildme::shell {echo newoutput > output.txt}
  }
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl -v -F] code out
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - run-sandbox$}] == 1}]
    expect cat-output [expr {[string match {*sample input*} $out]}]
  }
}} $helpers $root]

# buildme sandbox operates cleanly even when the suite files and directory are read-only
unit -name sandbox-readonly-source [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list readonly.txt "initial content\n"]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme

unit -name run-ro {
  package require buildme
  buildme::sandbox {
    # modify copied file (which would fail if permissions weren't made writable)
    set cat \[expr {\$::tcl_platform(platform) eq \"windows\" ? \"type\" : \"cat\"}\]
    buildme::shell {echo modified >> readonly.txt}
    buildme::shell \"\$cat readonly.txt\"
    # create new file in sandbox
    buildme::shell {echo created > created.txt}
  }
}
"]
  withfixture $pairs {
    # Make fixture files and directory read-only
    if {$::tcl_platform(platform) eq "windows"} {
      file attributes [file join $dir readonly.txt] -readonly 1
      file attributes [file join $dir test.tcl] -readonly 1
      file attributes $dir -readonly 1
    } else {
      file attributes [file join $dir readonly.txt] -permissions 0444
      file attributes [file join $dir test.tcl] -permissions 0444
      file attributes $dir -permissions 0555
    }
    try {
      lassign [capture tclsh $dir/test.tcl -v -F] code out
      expect clean-exit [expr {$code == 0}]
      expect unit-ok [expr {[matching $out {^ok \d+ - run-ro$}] == 1}]
      expect modified [expr {[string match {*modified*} $out]}]
    } finally {
      # restore permissions so fixture cleanup can remove dir
      if {$::tcl_platform(platform) eq "windows"} {
        file attributes $dir -readonly 0
        file attributes [file join $dir readonly.txt] -readonly 0
        file attributes [file join $dir test.tcl] -readonly 0
      } else {
        file attributes $dir -permissions 0755
      }
    }
  }
}} $helpers $root]

# buildme shell captures stderr on failure and reports errors
unit -name shell-failure [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme

unit -name run-fail {
  package require buildme
  buildme::sandbox {
    buildme::shell {exit 42}
  }
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect failed-exit [expr {$code == 1}]
    expect unit-failed [expr {[matching $out {^not ok \d+ - run-fail$}] == 1}]
  }
}} $helpers $root]

# buildme watchdog cleans up directories when immediate delete fails
unit -name sandbox-watchdog-cleanup [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
package require buildme

unit -name run-watchdog {
  package require buildme
  set target \[buildme::MakeTempDir\]
  set sub \[file join \$target locked\]
  file mkdir \$sub
  set f \[open \[file join \$sub file.txt\] w\]
  puts \$f {temporary}
  close \$f
  # Make subdirectory unreadable/unwritable on Linux, or hold file open on Windows
  if {\$::tcl_platform(platform) eq \"windows\"} {
    set lock \[open \[file join \$sub file.txt\] r\]
  } else {
    file attributes \$sub -permissions 0000
  }

  # Immediate delete fails
  set failed \[catch {file delete -force -- \$target}\]
  if {!\$failed} { error {expected immediate delete to fail} }

  # On Windows, close the lock handle so watchdog retries can clean it up
  if {\$::tcl_platform(platform) eq \"windows\"} {
    close \$lock
  }

  # Spawn watchdog with short timeout
  buildme::SpawnWatchdog \$target 5

  # Poll for up to 3 seconds for watchdog to clean it up
  set deadline \[expr {[clock seconds] + 3}\]
  while {\[file exists \$target\] && \[clock seconds\] < \$deadline} {
    after 100
  }
  if {\[file exists \$target\]} {
    # cleanup on failure
    catch {file attributes \$sub -permissions 0755}
    catch {file delete -force -- \$target}
    error {watchdog failed to clean up target directory}
  }
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - run-watchdog$}] == 1}]
  }
}} $helpers $root]
