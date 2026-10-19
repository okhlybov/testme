package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]

# Unit writes to the standard channels are tallied: puts, chan puts,
# partial lines and all
unit -name capture-basic [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name writer {
  puts PUTS-LINE
  puts -nonewline PART
  puts IAL
  chan puts stdout CHAN-LINE
  chan puts -nonewline stderr {chan partial }
  chan puts stderr joined
}
"]
  withfixture $pairs {
    # plain run: the TAP stream carries none of the unit output
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect stream-clean [expr {[matching $out {PUTS-LINE|PART|CHAN-LINE|chan partial|joined}] == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - writer$}] == 1}]
    # verbose run: the dump carries all of it, partial lines joined honestly
    lassign [capture tclsh $dir/test.tcl -v -F] code2 out2
    expect puts-captured [expr {[matching $out2 {PUTS-LINE}] == 1}]
    expect partial-joined [expr {[matching $out2 {^PARTIAL$}] == 1}]
    expect chan-captured [expr {[matching $out2 {CHAN-LINE}] == 1}]
    expect chan-partial-joined [expr {[matching $out2 {^chan partial joined$}] == 1}]
  }
}} $helpers $root]

# Non-ASCII output round-trips through the tally
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
    append body "unit -name leak$i \{puts \{FAKE ok 999 - injected \$i\}\nchan puts stdout \{FAKE exec-line\}\n\}
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

# The I/O escapes the basic capture cannot see are denied with a pointer
# to shellme instead of leaking into the TAP stream
unit -name deny-stream-escapes [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name redirector {
  exec echo EXECOUT-LEAK >@ stdout
}
unit -name copier {
  set f \[file tempfile path\]
  close \$f
  set h \[open \$path w\]
  puts \$h FCOPY-LEAK
  close \$h
  set h \[open \$path r\]
  fcopy \$h stdout
  close \$h
}
unit -name survivor {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect failed-exit [expr {$code == 1}]
    # the raw program output would stand on lines of its own; the deny
    # messages quoting the source (and its markers) are fine
    expect stream-clean [expr {[matching $out {^EXECOUT-LEAK$|^FCOPY-LEAK$}] == 0}]
    expect redirect-denied [expr {[matching $out {must not write to the process streams.*redirection to stdout}] == 1}]
    expect fcopy-denied [expr {[matching $out {must not write to the process streams.*fcopy to stdout}] == 1}]
    expect run-continues [expr {[matching $out {^ok \d+ - survivor$}] == 1}]
  }
}} $helpers $root]

# Unit stream redirection to files via -stdout, -stderr, -output
unit -name capture-file-redirection [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
set here \[file dirname \[info script\]\]
unit -name redir-split -stdout \[file join \$here out.log\] -stderr \[file join \$here err.log\] {
  puts stdout \"stdout line\"
  puts stderr \"stderr line\"
}
unit -name redir-combined -output \[file join \$here combined.log\] {
  puts stdout \"comb line 1\"
  puts stderr \"comb line 2\"
}
unit -name redir-same -stdout \[file join \$here same.log\] -stderr \[file join \$here same.log\] {
  puts stdout \"same line 1\"
  puts stderr \"same line 2\"
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect split-unit-ok [expr {[matching $out {^ok 1 - redir-split$}] == 1}]
    expect comb-unit-ok [expr {[matching $out {^ok 2 - redir-combined$}] == 1}]
    expect same-unit-ok [expr {[matching $out {^ok 3 - redir-same$}] == 1}]

    set f [open [file join $dir out.log] r]
    set outContent [read $f]
    close $f
    expect split-out [expr {[string trim $outContent] eq "stdout line"}]

    set f [open [file join $dir err.log] r]
    set errContent [read $f]
    close $f
    expect split-err [expr {[string trim $errContent] eq "stderr line"}]

    set f [open [file join $dir combined.log] r]
    set combContent [read $f]
    close $f
    expect comb-content [expr {[string match "*comb line 1*comb line 2*" $combContent]}]

    set f [open [file join $dir same.log] r]
    set sameContent [read $f]
    close $f
    expect same-content [expr {[string match "*same line 1*same line 2*" $sameContent]}]
  }
}} $helpers $root]
