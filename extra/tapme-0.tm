# tapme - a TAP (Test Anything Protocol) consumer for Tcl
# https://github.com/okhlybov/testme


package require Tcl 8.6-


# Makes the sibling modules discoverable no matter how this one is loaded
tcl::tm::add [file dirname [file normalize [info script]]]
package require clip


namespace eval ::tapme {


  variable plan {}
  variable expect 0
  variable count 0
  variable before no
  variable after no
  variable passed 0
  variable failed 0
  variable skipped 0
  variable todo 0
  variable bailed no
  variable casualties [list]
  variable warnings [list]
  variable lineno 0


  # Drops all the accumulated state
  proc reset {} {
    variable plan {}
    variable expect 0
    variable count 0
    variable before no
    variable after no
    variable passed 0
    variable failed 0
    variable skipped 0
    variable todo 0
    variable bailed no
    variable casualties [list]
    variable warnings [list]
    variable lineno 0
    return
  }


  proc warn {message} {
    variable warnings
    variable lineno
    lappend warnings "line $lineno: $message"
    return
  }


  # Consumes a single line of a TAP stream. Returns the test outcome keyword
  # (pass, fail, skip, todo) for the test lines and an empty string otherwise
  proc line {text} {
    variable plan
    variable expect
    variable count
    variable before
    variable after
    variable passed
    variable failed
    variable skipped
    variable todo
    variable bailed
    variable casualties
    variable lineno
    incr lineno
    set text [string trim $text]
    if {$text eq {}} {return {}}
    # Bail out! pragma
    if {[string match "Bail out!*" $text]} {
      if {!$bailed} {warn "bailing out due to the bail out! pragma"}
      set bailed yes
      return {}
    }
    # Plan line
    if {[regexp {^1\.\.(\d+)$} $text ~ n]} {
      if {$plan ne {}} {
        warn "more than one plan line"
        return {}
      }
      set plan $text
      set expect $n
      return {}
    }
    # Test lines
    if {[regexp {^(not\s+ok|ok)(\s.*)?$} $text ~ verdict rest]} {
      if {$plan eq {}} {
        set before yes
      } else {
        set after yes
      }
      incr count
      set ok [expr {$verdict eq "ok"}]
      set number {}
      set name {}
      set directive {}
      set rest [string trim $rest]
      if {[regexp {^(\d+)(\s+(.*))?$} $rest ~ number ~ rest]} {
        set rest [string trim $rest]
        if {$expect != 0 && ($number < 1 || $number > $expect)} {
          warn "test point number $number is out of range for the plan $plan"
        }
      }
      set hash [string first {#} $rest]
      if {$hash >= 0} {
        set directive [string trim [string range $rest [expr {$hash + 1}] end]]
        set rest [string trim [string range $rest 0 [expr {$hash - 1}]]]
      }
      regsub {^-\s*} $rest {} rest
      set name [string trim $rest]
      set kind [string toupper [lindex $directive 0]]
      if {!$ok && $kind ne {TODO}} {
        incr failed
        set tag $number
        if {$tag eq {}} {set tag $count}
        if {$name ne {}} {
          lappend casualties "$tag - $name"
        } else {
          lappend casualties $tag
        }
        return fail
      }
      switch $kind {
        SKIP {incr skipped; return skip}
        TODO {incr todo; return todo}
        default {incr passed; return pass}
      }
    }
    # The rest of the lines: comments, YAML blocks, garbage - ignored
    return {}
  }


  # Returns the trailing report as a list of TAP comment lines. The missing
  # plan line complaint is suppressed in the streaming mode, ex. when
  # consuming the outputs of multiple concatenated sources
  proc summary {{streaming no}} {
    variable plan
    variable expect
    variable count
    variable before
    variable after
    variable passed
    variable failed
    variable skipped
    variable todo
    variable bailed
    variable casualties
    variable warnings
    set out [list]
    if {!$streaming && $plan eq {} && $count > 0} {
      lappend out "# missing a plan line"
    }
    if {$before && $after} {
      lappend out "# a plan line may only be placed before or after all tests"
    }
    if {$plan ne {} && $count > $expect} {
      lappend out "# expected $expect tests but $count ran"
    }
    if {$plan ne {} && $count < $expect} {
      lappend out "# expected $expect tests but only $count ran"
    }
    foreach w $warnings {lappend out "# $w"}
    if {$plan ne {}} {
      lappend out "# $count of $expect tests: $passed passed, $failed failed, $skipped skipped, $todo todo"
    } else {
      lappend out "# $count tests: $passed passed, $failed failed, $skipped skipped, $todo todo"
    }
    if {[llength $casualties]} {lappend out "# failed: [join $casualties {, }]"}
    if {$bailed} {lappend out "# bailed out"}
    return $out
  }


  # The failed tests tally accessor
  proc failed {} {
    variable failed
    return $failed
  }


}


# CLI mode: consume a TAP stream from the standard input channel
if {[info script] ne {} && [info exists ::argv0] && $::argv0 ne {} && [file normalize [info script]] eq [file normalize $::argv0]} {


  package provide tapme 0


  set streaming false
  if {[catch {


    set ::tapme_opts {
      {{-s --streaming} -info "do not complain about a missing plan line" -default true -slot streaming}
      {{-h --help} -info "print help" -apply {
        puts stderr "usage: [file tail $::argv0] {--flag --opt=arg} {--} {< stream}"
        puts stderr {}
        clip::usage $::tapme_opts {} stderr
        exit 0
      }}
      {{--version} -info "print package version" -apply {
        puts stderr [package present tapme]
        exit 0
      }}
    }
    if {[llength $::argv]} {set ::argv [clip::parse $::argv $::tapme_opts]}
  } e]} {
    puts stderr $e
    exit 1
  }


  set marks 0
  while {[gets stdin line] >= 0} {
    switch [::tapme::line $line] {
      pass {puts -nonewline .; incr marks; flush stdout}
      fail {puts -nonewline F; incr marks; flush stdout}
      skip {puts -nonewline s; incr marks; flush stdout}
    }
  }
  if {$marks} {puts {}; flush stdout}
  foreach l [::tapme::summary $streaming] {puts $l}
  exit [expr {[::tapme::failed] > 0 ? 1 : 0}]


}
