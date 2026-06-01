"""infrastructure.tags -- the ONLY place that talks to system.tag.

Wrapping tag access here means:
  * the rest of the code depends on a small, named API (read_unit, write_setpoint)
    instead of scattering tag-path strings everywhere;
  * if the UDT layout changes, you edit one module;
  * the application/domain layers stay testable (you can stub these functions).

Tag layout assumed (a 'Refrigeration Unit' UDT instance per unit):
    [default]Refrigeration/<unit>/Temperature   (Float)
    [default]Refrigeration/<unit>/Setpoint       (Float)
    [default]Refrigeration/<unit>/LowLimit        (Float)
    [default]Refrigeration/<unit>/HighLimit       (Float)
    [default]Refrigeration/<unit>/Running         (Boolean)
    [default]Refrigeration/<unit>/AlarmAcked       (Boolean)
"""

# Jython 2.7 (Ignition).

from common import log
from common import util

logger = log.get("infrastructure.tags")

PROVIDER = "default"
BASE_PATH = "Refrigeration"

# Members read for one unit, in a fixed order so we can zip the results back.
_MEMBERS = ["Temperature", "Setpoint", "LowLimit", "HighLimit", "Running"]


def unit_path(unit):
    """Build the fully-qualified UDT instance path for a unit name."""
    return "[%s]%s/%s" % (PROVIDER, BASE_PATH, unit)


def read_unit(unit):
    """Read one unit's tags in a single readBlocking call.

    Returns a dict of plain Python values (floats / bool). Bad-quality reads
    fall back to safe defaults so callers don't have to inspect QualifiedValue.
    """
    base = unit_path(unit)
    paths = ["%s/%s" % (base, m) for m in _MEMBERS]
    qvs = system.tag.readBlocking(paths)

    values = {}
    for member, qv in zip(_MEMBERS, qvs):
        if not qv.quality.isGood():
            logger.warn("bad quality reading %s/%s: %s"
                        % (base, member, qv.quality))
        values[member] = qv.value

    return {
        "name": unit,
        "temp_c": util.to_float(values.get("Temperature")),
        "setpoint_c": util.to_float(values.get("Setpoint")),
        "low_limit_c": util.to_float(values.get("LowLimit"), -30.0),
        "high_limit_c": util.to_float(values.get("HighLimit"), 5.0),
        "running": bool(values.get("Running")),
    }


def write_setpoint(unit, setpoint_c):
    """Write a new setpoint. Returns True if the write reported Good quality."""
    path = "%s/Setpoint" % unit_path(unit)
    result = system.tag.writeBlocking([path], [setpoint_c])[0]
    ok = result.isGood()
    if not ok:
        logger.error("setpoint write to %s failed: %s" % (path, result))
    return ok


def set_alarm_acked(unit, acked=True):
    """Flag a unit's alarm as acknowledged."""
    path = "%s/AlarmAcked" % unit_path(unit)
    return system.tag.writeBlocking([path], [acked])[0].isGood()
