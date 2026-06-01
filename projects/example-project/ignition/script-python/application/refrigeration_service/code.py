"""application.refrigeration_service -- use cases for the refrigeration line.

This is the orchestration layer. It does no I/O of its own and holds no business
rules of its own: it pulls data through infrastructure.*, applies
domain.refrigeration, and pushes results back out. A Gateway Timer Script, a
tag event, or a Perspective button can all call into here.

    # e.g. from a Gateway Timer Script (every 30s):
    application.refrigeration_service.evaluate_all(["Compressor-1", "Tower-2"])
"""

# Jython 2.7 (Ignition).

from common import log
from domain import refrigeration
from infrastructure import tags
from infrastructure import db

logger = log.get("application.refrigeration")


def evaluate_unit(unit):
    """Read one unit, classify it, persist the reading, return a UnitReading.

    Returns None if the unit could not be read/evaluated (already logged).
    """
    try:
        raw = tags.read_unit(unit)
        reading = refrigeration.UnitReading(
            name=raw["name"],
            temp_c=raw["temp_c"],
            setpoint_c=raw["setpoint_c"],
            low_limit_c=raw["low_limit_c"],
            high_limit_c=raw["high_limit_c"],
            running=raw["running"],
        )
        db.log_reading(reading.name, reading.temp_c, reading.status)

        if reading.actionable:
            logger.warn("%s is %s (%.1f C, setpoint %.1f C)"
                        % (reading.name, reading.status,
                           reading.temp_c, reading.setpoint_c))
        return reading
    except Exception as e:
        logger.error("failed to evaluate unit %s: %s" % (unit, e))
        return None


def evaluate_all(units):
    """Evaluate a list of units. Returns the list of successful UnitReadings.

    One bad unit never aborts the rest -- evaluate_unit swallows and logs.
    """
    results = []
    for unit in units:
        reading = evaluate_unit(unit)
        if reading is not None:
            results.append(reading)

    actionable = [r for r in results if r.actionable]
    logger.info("evaluated %d units, %d actionable"
                % (len(results), len(actionable)))
    return results


def acknowledge_alarm(unit, actor="system"):
    """Acknowledge a unit's alarm and record who did it."""
    ok = tags.set_alarm_acked(unit, True)
    if ok:
        logger.info("alarm on %s acknowledged by %s" % (unit, actor))
    else:
        logger.error("failed to acknowledge alarm on %s" % unit)
    return ok
