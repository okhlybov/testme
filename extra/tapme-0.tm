# tapme - a TAP (Test Anything Protocol) consumer for Tcl
# https://github.com/okhlybov/testme


package require Tcl 8.6-


# Makes the sibling modules discoverable no matter how this one is loaded
catch {tcl::tm::path add [file normalize [file join [file dirname [file normalize [info script]]] ..]]}
catch {tcl::tm::path add [file dirname [file normalize [info script]]]}
package require clip

package provide tapme 0


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
  variable bailed_reason {}
  variable casualties [list]
  variable warnings [list]
  variable lineno 0

  variable total_count 0
  variable total_passed 0
  variable total_failed 0
  variable total_skipped 0
  variable total_todo 0

  variable in_yaml 0
  variable yaml_lines [list]
  variable diagnostics [dict create]
  variable last_tag {}
  variable version {}
  variable skipped_all no
  variable skip_reason {}
  variable nextSubtestName {}
  variable stack [list]


  proc DefaultScope {{depth 0} {name {}}} {
    dict create \
      depth $depth \
      name $name \
      plan {} \
      expect 0 \
      count 0 \
      before no \
      after no \
      passed 0 \
      failed 0 \
      skipped 0 \
      todo 0 \
      seen [dict create] \
      casualties [list] \
      skip_all {} \
      skipped_all no \
      skip_reason {}
  }


  proc SyncTopScope {} {
    variable stack
    variable plan
    variable expect
    variable count
    variable before
    variable after
    variable passed
    variable failed
    variable skipped
    variable todo
    variable casualties
    variable skipped_all
    variable skip_reason
    if {![llength $stack]} { return }
    set top [lindex $stack 0]
    set plan [dict get $top plan]
    set expect [dict get $top expect]
    set count [dict get $top count]
    set before [dict get $top before]
    set after [dict get $top after]
    set passed [dict get $top passed]
    set failed [dict get $top failed]
    set skipped [dict get $top skipped]
    set todo [dict get $top todo]
    set casualties [dict get $top casualties]
    set skipped_all [dict get $top skipped_all]
    set skip_reason [dict get $top skip_reason]
  }


  proc PopScope {} {
    variable stack
    variable warnings
    if {[llength $stack] <= 1} { return }
    set scope [lindex $stack end]
    set stack [lrange $stack 0 end-1]
    set name [dict get $scope name]
    set sPlan [dict get $scope plan]
    set sExpect [dict get $scope expect]
    set sCount [dict get $scope count]
    set sBefore [dict get $scope before]
    set sAfter [dict get $scope after]
    set sSkippedAll [dict get $scope skipped_all]
    set prefix [expr {$name ne {} ? "subtest '$name': " : "subtest: "}]
    if {$sPlan eq {} && $sCount > 0} {
      warn "${prefix}missing a plan line"
    }
    if {$sBefore && $sAfter} {
      warn "${prefix}a plan line may only be placed before or after all tests"
    }
    if {$sPlan ne {} && !$sSkippedAll && $sCount > $sExpect} {
      warn "${prefix}expected $sExpect tests but $sCount ran"
    }
    if {$sPlan ne {} && !$sSkippedAll && $sCount < $sExpect} {
      warn "${prefix}expected $sExpect tests but only $sCount ran"
    }
    return $scope
  }


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
    variable bailed_reason {}
    variable casualties [list]
    variable warnings [list]
    variable lineno 0

    variable total_count 0
    variable total_passed 0
    variable total_failed 0
    variable total_skipped 0
    variable total_todo 0

    variable in_yaml 0
    variable yaml_lines [list]
    variable diagnostics [dict create]
    variable last_tag {}
    variable version {}
    variable skipped_all no
    variable skip_reason {}
    variable nextSubtestName {}
    variable stack [list [DefaultScope 0 {}]]
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
    variable bailed_reason
    variable casualties
    variable lineno
    variable in_yaml
    variable yaml_lines
    variable diagnostics
    variable last_tag
    variable version
    variable nextSubtestName
    variable stack
    variable total_count
    variable total_passed
    variable total_failed
    variable total_skipped
    variable total_todo

    incr lineno
    set trimmed [string trim $text]
    if {$trimmed eq {}} { return {} }

    # Handle YAML diagnostic blocks
    if {$in_yaml} {
      if {[regexp {^[ ]*\.\.\.\s*$} $text]} {
        set in_yaml 0
        if {$last_tag ne {}} {
          dict set diagnostics $last_tag [join $yaml_lines \n]
        }
        return {}
      }
      lappend yaml_lines $text
      return {}
    }
    if {[regexp {^[ ]*---\s*$} $text]} {
      set in_yaml 1
      set yaml_lines [list]
      return {}
    }

    # TAP version declaration
    if {[regexp {^[ ]*TAP\s+version\s+(\d+)\s*$} $text ~ ver]} {
      set version $ver
      if {$ver < 13} { warn "unsupported TAP version $ver" }
      return {}
    }

    # Bail out! pragma
    if {[regexp {^[ ]*Bail\s+out!(?:\s*(.*))?$} $text ~ reason]} {
      if {!$bailed} { warn "bailing out due to the bail out! pragma" }
      set bailed yes
      set bailed_reason [string trim $reason]
      return {}
    }

    # Subtest announcement comment: # Subtest: <name>
    if {[regexp {^[ ]*#\s*Subtest:\s*(.*)$} $text ~ subname]} {
      set nextSubtestName [string trim $subname]
      return {}
    }

    # Comment lines (and pragmas) are ignored without altering indentation level
    if {[string index $trimmed 0] eq "#" || [regexp {^pragma\s+[+-]} $trimmed]} {
      return {}
    }

    # Determine indentation level (4 spaces or 1 tab per level)
    set indent 0
    set len [string length $text]
    for {set i 0} {$i < $len} {incr i} {
      set c [string index $text $i]
      if {$c eq " "} {
        incr indent
      } elseif {$c eq "\t"} {
        incr indent 4
      } else {
        break
      }
    }
    set level [expr {$indent / 4}]

    # Plan line: 1..N or 1..0 # SKIP [reason]
    if {[regexp {^1\.\.(\d+)(?:\s*#\s*(.*))?$} $trimmed ~ n comment]} {
      while {[llength $stack] - 1 > $level} {
        PopScope
      }
      while {[llength $stack] - 1 < $level} {
        lappend stack [DefaultScope [llength $stack] $nextSubtestName]
        set nextSubtestName {}
      }
      set idx [expr {[llength $stack] - 1}]
      set scope [lindex $stack $idx]
      if {[dict get $scope plan] ne {}} {
        warn "more than one plan line"
        return {}
      }
      dict set scope plan $trimmed
      dict set scope expect $n
      if {$n == 0} {
        dict set scope skipped_all yes
        if {[regexp -nocase {^skip[:\s]*(.*)$} [string trim $comment] ~ sreason]} {
          dict set scope skip_reason [string trim $sreason]
        } else {
          dict set scope skip_reason [string trim $comment]
        }
      }
      lset stack $idx $scope
      SyncTopScope
      return {}
    }

    # Test line: ok / not ok
    if {[regexp {^(not\s+ok|ok)(\s.*)?$} $trimmed ~ verdict rest]} {
      while {[llength $stack] - 1 > $level} {
        PopScope
      }
      while {[llength $stack] - 1 < $level} {
        lappend stack [DefaultScope [llength $stack] $nextSubtestName]
        set nextSubtestName {}
      }
      set idx [expr {[llength $stack] - 1}]
      set scope [lindex $stack $idx]

      if {[dict get $scope plan] eq {}} {
        dict set scope before yes
      } else {
        dict set scope after yes
      }
      dict incr scope count
      incr total_count
      set curCount [dict get $scope count]
      set ok [expr {$verdict eq "ok"}]
      set number {}
      set name {}
      set directive {}
      set rest [string trim $rest]
      if {[regexp {^(\d+)(\s+(.*))?$} $rest ~ number ~ rest]} {
        set rest [string trim $rest]
        set exp [dict get $scope expect]
        if {$exp != 0 && ($number < 1 || $number > $exp)} {
          set p [dict get $scope plan]
          warn "test point number $number is out of range for the plan $p"
        }
        if {[dict exists [dict get $scope seen] $number]} {
          warn "duplicate test point number $number"
        }
        dict set scope seen $number 1
      }
      set hash [string first {#} $rest]
      if {$hash >= 0} {
        set directive [string trim [string range $rest [expr {$hash + 1}] end]]
        set rest [string trim [string range $rest 0 [expr {$hash - 1}]]]
      }
      regsub {^-\s*} $rest {} rest
      set name [string trim $rest]
      set kind [string toupper [lindex $directive 0]]
      set tag $number
      if {$tag eq {}} { set tag $curCount }
      set last_tag $tag
      set outcome {}
      if {!$ok && $kind ne {TODO}} {
        dict incr scope failed
        incr total_failed
        if {$name ne {}} {
          dict lappend scope casualties "$tag - $name"
        } else {
          dict lappend scope casualties $tag
        }
        set outcome fail
      } else {
        switch $kind {
          SKIP {
            dict incr scope skipped
            incr total_skipped
            set outcome skip
          }
          TODO {
            dict incr scope todo
            incr total_todo
            set outcome todo
          }
          default {
            dict incr scope passed
            incr total_passed
            set outcome pass
          }
        }
      }
      lset stack $idx $scope
      SyncTopScope
      return $outcome
    }

    # The rest of the lines: unrecognized lines - ignored
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
    variable bailed_reason
    variable casualties
    variable warnings
    variable skipped_all
    variable skip_reason
    variable stack

    while {[llength $stack] > 1} {
      PopScope
    }
    SyncTopScope

    set out [list]
    if {!$streaming && $plan eq {} && $count > 0} {
      lappend out "# missing a plan line"
    }
    if {$before && $after} {
      lappend out "# a plan line may only be placed before or after all tests"
    }
    if {$plan ne {} && !$skipped_all && $count > $expect} {
      lappend out "# expected $expect tests but $count ran"
    }
    if {$plan ne {} && !$skipped_all && $count < $expect} {
      lappend out "# expected $expect tests but only $count ran"
    }
    foreach w $warnings { lappend out "# $w" }
    if {$plan ne {}} {
      if {$expect == 0 && $skipped_all} {
        if {$skip_reason ne {}} {
          lappend out "# 0 of 0 tests: skipped ($skip_reason)"
        } else {
          lappend out "# 0 of 0 tests: skipped"
        }
      } else {
        lappend out "# $count of $expect tests: $passed passed, $failed failed, $skipped skipped, $todo todo"
      }
    } else {
      lappend out "# $count tests: $passed passed, $failed failed, $skipped skipped, $todo todo"
    }
    if {[llength $casualties]} { lappend out "# failed: [join $casualties {, }]" }
    if {$bailed} {
      if {$bailed_reason ne {}} {
        lappend out "# bailed out ($bailed_reason)"
      } else {
        lappend out "# bailed out"
      }
    }
    return $out
  }


  # The failed tests tally accessor
  proc failed {{total no}} {
    variable failed
    variable total_failed
    return [expr {$total ? $total_failed : $failed}]
  }


  proc passed {{total no}} {
    variable passed
    variable total_passed
    return [expr {$total ? $total_passed : $passed}]
  }


  proc skipped {{total no}} {
    variable skipped
    variable total_skipped
    return [expr {$total ? $total_skipped : $skipped}]
  }


  proc todo {{total no}} {
    variable todo
    variable total_todo
    return [expr {$total ? $total_todo : $todo}]
  }


  proc count {{total no}} {
    variable count
    variable total_count
    return [expr {$total ? $total_count : $count}]
  }


  proc plan {} {
    variable plan
    return $plan
  }


  proc expect {} {
    variable expect
    return $expect
  }


  proc bailed {} {
    variable bailed
    return $bailed
  }


  proc casualties {} {
    variable casualties
    return $casualties
  }


  proc warnings {} {
    variable warnings
    return $warnings
  }


  proc version {} {
    variable version
    return $version
  }


  proc diagnostics {} {
    variable diagnostics
    return $diagnostics
  }


  proc ok {} {
    variable failed
    variable bailed
    variable plan
    variable expect
    variable count
    variable skipped_all
    if {$bailed} { return 0 }
    if {$failed > 0} { return 0 }
    if {$plan ne {} && !$skipped_all && $count != $expect} { return 0 }
    return 1
  }


  # Initialize state
  reset


}


# CLI mode: consume a TAP stream from the standard input channel
if {[info script] ne {} && [info exists ::argv0] && $::argv0 ne {} && [file normalize [info script]] eq [file normalize $::argv0]} {

  catch {fconfigure stdout -buffering none}
  catch {fconfigure stdin -buffering line}

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
      todo {puts -nonewline x; incr marks; flush stdout}
    }
  }
  if {$marks} {puts {}; flush stdout}
  foreach l [::tapme::summary $streaming] {puts $l}
  exit [expr {[::tapme::ok] ? 0 : 1}]

}
