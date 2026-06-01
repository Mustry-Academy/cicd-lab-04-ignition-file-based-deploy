"""domain.refrigeration -- pure refrigeration business rules.

This module is deliberately FREE of any Ignition API (no system.tag, system.db,
system.perspective). It takes plain numbers in and returns plain values out,
which is exactly why it can be unit-tested from the Script Console with no
running gateway state -- see tests.test_refrigeration.

Keeping the rules here (instead of inline in a tag event or a Perspective
binding) means there is one place to change "what counts as an alarm", and one
place to test it.
"""

# Jython 2.7 (Ignition). Pure Python only -- do not import system.* here.

# Status values, ordered by severity.
OFF = "OFF"
NORMAL = "NORMAL"
WARNING = "WARNING"
ALARM = "ALARM"

# A reading within this band of the high/low limit is a WARNING, not yet ALARM.
WARNING_MARGIN_C = 1.5


def c_to_f(celsius):
    """Celsius -> Fahrenheit."""
    return celsius * 9.0 / 5.0 + 32.0


def f_to_c(fahrenheit):
    """Fahrenheit -> Celsius."""
    return (fahrenheit - 32.0) * 5.0 / 9.0


def deviation(temp_c, setpoint_c):
    """Signed deviation from setpoint (positive = too warm)."""
    return temp_c - setpoint_c


def classify(temp_c, low_limit_c, high_limit_c, running):
    """Classify a refrigeration unit's state from its current reading.

    Args:
        temp_c: current temperature, degrees C.
        low_limit_c: alarm threshold on the cold side.
        high_limit_c: alarm threshold on the warm side.
        running: whether the unit is currently running.

    Returns:
        One of OFF / NORMAL / WARNING / ALARM.
    """
    if not running:
        return OFF
    if temp_c >= high_limit_c or temp_c <= low_limit_c:
        return ALARM
    if (temp_c >= high_limit_c - WARNING_MARGIN_C or
            temp_c <= low_limit_c + WARNING_MARGIN_C):
        return WARNING
    return NORMAL


def is_actionable(status):
    """True when an operator should be notified (WARNING or ALARM)."""
    return status in (WARNING, ALARM)


class UnitReading(object):
    """Value object: an evaluated snapshot of one refrigeration unit.

    Construct it from raw numbers, then ask it for derived facts. No I/O.
    """

    def __init__(self, name, temp_c, setpoint_c, low_limit_c, high_limit_c,
                 running):
        self.name = name
        self.temp_c = temp_c
        self.setpoint_c = setpoint_c
        self.low_limit_c = low_limit_c
        self.high_limit_c = high_limit_c
        self.running = running
        self.status = classify(temp_c, low_limit_c, high_limit_c, running)

    @property
    def deviation_c(self):
        return deviation(self.temp_c, self.setpoint_c)

    @property
    def actionable(self):
        return is_actionable(self.status)

    def as_dict(self):
        """Plain dict -- handy for logging or handing to the presentation layer."""
        return {
            "name": self.name,
            "tempC": self.temp_c,
            "setpointC": self.setpoint_c,
            "deviationC": self.deviation_c,
            "status": self.status,
            "running": self.running,
        }

    def __repr__(self):
        return "<UnitReading %s %.1fC %s>" % (self.name, self.temp_c, self.status)
