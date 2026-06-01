"""tests.test_refrigeration -- gateway-free tests for domain.refrigeration.

Because domain.refrigeration touches no system.* API, we can exercise it with
plain assertions. Run from the Script Console (or a Gateway Event for CI):

    tests.test_refrigeration.run()

Prints a summary and returns True if everything passed. This is the payoff of
keeping business rules in a pure layer -- the rules are testable without tags,
a database, or a running line.
"""

# Jython 2.7 (Ignition).

from domain import refrigeration as r


def _check(name, condition, failures):
    if condition:
        return True
    failures.append(name)
    return False


def run():
    """Execute all checks. Returns True if all passed."""
    failures = []

    # --- temperature conversion (round-trip) ---
    _check("c_to_f freezing", abs(r.c_to_f(0.0) - 32.0) < 1e-9, failures)
    _check("f_to_c boiling", abs(r.f_to_c(212.0) - 100.0) < 1e-9, failures)
    _check("convert round-trip",
           abs(r.f_to_c(r.c_to_f(-18.0)) - (-18.0)) < 1e-9, failures)

    # --- deviation ---
    _check("deviation positive = too warm",
           r.deviation(4.0, 2.0) == 2.0, failures)

    # --- classify ---
    _check("not running -> OFF",
           r.classify(2.0, -30.0, 5.0, running=False) == r.OFF, failures)
    _check("mid-band -> NORMAL",
           r.classify(0.0, -30.0, 5.0, running=True) == r.NORMAL, failures)
    _check("near high limit -> WARNING",
           r.classify(4.0, -30.0, 5.0, running=True) == r.WARNING, failures)
    _check("over high limit -> ALARM",
           r.classify(6.0, -30.0, 5.0, running=True) == r.ALARM, failures)
    _check("under low limit -> ALARM",
           r.classify(-31.0, -30.0, 5.0, running=True) == r.ALARM, failures)

    # --- UnitReading value object ---
    reading = r.UnitReading("Compressor-1", temp_c=6.0, setpoint_c=2.0,
                            low_limit_c=-30.0, high_limit_c=5.0, running=True)
    _check("reading status ALARM", reading.status == r.ALARM, failures)
    _check("reading actionable", reading.actionable is True, failures)
    _check("reading deviation", reading.deviation_c == 4.0, failures)
    _check("reading as_dict has status",
           reading.as_dict().get("status") == r.ALARM, failures)

    total = 13
    passed = total - len(failures)
    print("test_refrigeration: %d/%d passed" % (passed, total))
    for name in failures:
        print("  FAILED: %s" % name)
    return len(failures) == 0
