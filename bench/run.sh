#! /bin/sh
# testme - a testing pico framework for Tcl
# https://github.com/okhlybov/testme

# The throughput benchmark of the trivial units; see bench.tcl for the details
# usage: sh bench/run.sh ?units? ?subprocess-units?

dir=`dirname "$0"`
exec tclsh "$dir/bench.tcl" "$@"
