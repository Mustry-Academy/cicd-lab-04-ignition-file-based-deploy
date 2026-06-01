# -*- coding: utf-8 -*-
"""presentation.refrigeration_view -- helpers a Perspective view calls.

This layer adapts domain/application output into shapes the UI wants: formatted
strings, colors, and a table dataset. It is the only script layer that knows
about display concerns (units, hex colors, column names).

Typical use from a Perspective component:
    * Expression binding -> runScript:
        runScript("presentation.refrigeration_view.format_temperature",
                  0, {value}, "F")
    * Property binding -> script transform calling build_units_table(...)
"""

# Jython 2.7 (Ignition).

from domain import refrigeration
from application import refrigeration_service
from common import util

# Status -> hex color, for a Perspective style/binding.
_STATUS_COLOR = {
    refrigeration.OFF: "#9E9E9E",      # grey
    refrigeration.NORMAL: "#2E7D32",   # green
    refrigeration.WARNING: "#F9A825",  # amber
    refrigeration.ALARM: "#C62828",    # red
}


def format_temperature(value_c, units="C"):
    """Format a Celsius value for display, optionally converting to Fahrenheit.

    Returns "--" for missing/bad input so the UI never shows "None".
    """
    c = util.round_to(value_c, 2)
    if c is None:
        return "--"
    if units.upper() == "F":
        return u"%.1f °F" % refrigeration.c_to_f(c)
    return u"%.1f °C" % c


def status_color(status):
    """Hex color for a status string (safe default for unknown values)."""
    return _STATUS_COLOR.get(status, "#9E9E9E")


def build_units_table(units):
    """Build a list-of-dicts the Perspective Table component can bind to.

    Each row carries display fields plus a 'color' the table can use for
    conditional styling. Pure transform over the application layer's output.
    """
    rows = []
    for reading in refrigeration_service.evaluate_all(units):
        rows.append({
            "unit": reading.name,
            "temperature": format_temperature(reading.temp_c, "C"),
            "setpoint": format_temperature(reading.setpoint_c, "C"),
            "deviation": u"%+.1f °C" % reading.deviation_c,
            "status": reading.status,
            "color": status_color(reading.status),
        })
    return rows
