package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]

# Everything the unit writes through the channel stack is captured,
# not just puts: chan puts and fcopy alike
unit -name capture-chan-and-fcopy [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name writer {
  chan puts stdout CHANPUTS-LINE
  set f \[file tempfile path\]
  close \$f
  set f \[open \$path w\]
  puts \$f FCOPY-LINE
  close \$f
  set f \[open \$path r\]
  fcopy \$f stdout
  close \$f
  file delete \$path
}
"]
  withfixture $pairs {
    # plain run: the TAP stream carries none of the unit output
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect stream-clean [expr {[matching $out {CHANPUTS-LINE|FCOPY-LINE}] == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - writer$}] == 1}]
    # verbose run: the dump carries all of it
    lassign [capture tclsh $dir/test.tcl -v -F] code2 out2
    expect chanputs-captured [expr {[matching $out2 {CHANPUTS-LINE}] >= 1}]
    expect fcopy-captured [expr {[matching $out2 {FCOPY-LINE}] >= 1}]
  }
}} $helpers $root]

# Output of programs redirected onto the process streams is captured too
unit -name capture-exec-redirections [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name redirector {
  exec echo EXECOUT-LEAK >@ stdout
  exec sh -c {echo EXECERR-LEAK >&2} 2>@ stderr
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect stream-clean [expr {[matching $out {EXECOUT-LEAK|EXECERR-LEAK}] == 0}]
    lassign [capture tclsh $dir/test.tcl -v -F] code2 out2
    expect stdout-redirect-captured [expr {[matching $out2 {EXECOUT-LEAK}] >= 1}]
    expect stderr-redirect-captured [expr {[matching $out2 {EXECERR-LEAK}] >= 1}]
  }
}} $helpers $root]

# Non-ASCII output round-trips through the capture
unit -name capture-utf8 [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name unicode {
  puts {héllo wörld ☃}
  chan puts stdout {chan héllo}
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl -v -F] code out
    expect clean-exit [expr {$code == 0}]
    expect utf8-roundtrip [expr {[matching $out {héllo wörld ☃}] == 1}]
    expect chan-utf8 [expr {[matching $out {chan héllo}] == 1}]
    expect unit-ok [expr {[matching $out {^ok \d+ - unicode$}] == 1}]
  }
}} $helpers $root]

# A flock of noisy parallel units leaves the TAP stream pure
unit -name capture-parallel-purity [list apply {{helpers root} {
  source $helpers
  set body "tcl::tm::add $root
package require testme
"
  for {set i 0} {$i < 50} {incr i} {
    append body "unit -name leak$i \{puts \{FAKE ok 999 - injected \$i\}\nexec sh -c \{echo FAKE-exec-line\} >@ stdout\n\}
"
  }
  set pairs [list [list test.tcl $body]]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect no-fake-points [expr {[matching $out {FAKE}] == 0}]
    expect all-passed [expr {[matching $out {^ok \d+ - leak\d+$}] == 50}]
    lassign [capture tclsh $dir/test.tcl -s] code2 out2
    expect serial-clean [expr {$code2 == 0 && [matching $out2 {FAKE}] == 0}]
  }
}} $helpers $root]
