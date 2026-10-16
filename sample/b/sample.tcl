package require testme

# The expected shape: a parametrization cycle submitting the whole series at once
foreach x {p q r} {
  unit -name "param-$x" -tags {slow} [list string toupper $x]
}

# Suite diagnostics belong to stderr: stdout during collection is refused
# (it is the TAP channel of the run itself)
puts stderr b
