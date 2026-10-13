# Shared testme self-test harness and assertion library

set dir [file dirname [file normalize [info script]]]
set root [file normalize [file join $dir ..]]

tcl::tm::add $root
package require testme


# The unit-side helper library, prepended to every unit body: assertion
# helpers and the sub-suite runner. Executes in the unit interpreter, so it
# can use the `context` accessor and the `unit` record variable alike
set lib {
    proc expect {what args} {
        if {[llength $args] == 1} {
            set cond [lindex $args 0]
        } elseif {[llength $args] == 3} {
            lassign $args a op b
            switch -- $op {
                == {set cond [expr {$a == $b}]}
                != {set cond [expr {$a != $b}]}
                eq {set cond [expr {$a eq $b}]}
                ne {set cond [expr {$a ne $b}]}
                default {set cond [expr [list $a] $op [list $b]]}
            }
        } else {
            set cond [expr {*}$args]
        }
        if {!$cond} {error "expected: $what"}
        return
    }


    proc expect-match {what text pattern} {
        if {![regexp -- $pattern $text]} {
            error "expected $what matching /$pattern/\ngot: $text"
        }
        return
    }


    proc exitcode {opts} {
        if {[dict exists $opts -errorcode] && [lindex [dict get $opts -errorcode] 0] eq {CHILDSTATUS}} {
            return [lindex [dict get $opts -errorcode] 2]
        }
        return 0
    }


    # Generates a sub-suite (gen.tcl) in the unit staging directory, runs it
    # through the real tclsh and returns the outcome as a dict:
    #   code - tcl-level catch code, exit - the process exit status, out -
    #   the combined standard output & error channels
    proc run {body args} {
        upvar 1 unit unit
        package require buildme
        buildme::sandbox {
            set g [file join [dict get $unit -stage] gen.tcl]
            set f [open $g w]
            puts $f "cd {[dict get $unit -stage]}"
            puts $f "tcl::tm::add {[context -root]}"
            puts $f "tcl::tm::add {[dict get $unit -stage]}"
            if {[regexp -- {^[ \t]*package require testme} [string trimleft $body]]} {
                puts $f $body
            } elseif {[regexp -- {^(.*?\n)([ \t]*testme::unit.*)$} $body ~ pre post]} {
                puts $f $pre
                puts $f {package require testme}
                puts $f $post
            } else {
                puts $f {package require testme}
                puts $f $body
            }
            close $f
            if {[llength $args] == 1 && [llength [lindex $args 0]] > 1} {
                set args [lindex $args 0]
            }
            set caught [catch {exec [info nameofexecutable] $g {*}$args 2>@1} out opts]
            return [dict create code $caught exit [exitcode $opts] out $out]
        }
    }
}


# The suite-layer wrapper: composes the helper library into every unit body
proc unit-test {name body {opts {}}} {
    tailcall testme::unit -name $name -root $::root {*}$opts "$::lib\n$body"
}
