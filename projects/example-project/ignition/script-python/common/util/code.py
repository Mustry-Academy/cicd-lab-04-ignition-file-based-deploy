"""common.util -- small, dependency-light helpers shared across layers.

Keep this module tiny and side-effect free. Anything that touches tags, the
database, or Perspective belongs in infrastructure/ or presentation/, not here.
"""

# Jython 2.7 (Ignition).


def to_float(value, default=0.0):
    """Best-effort float conversion that never raises.

    Tag reads and UI inputs can arrive as None, "", or a stray string. Use this
    at the boundary so the rest of the code can assume a real number.
    """
    if value is None:
        return default
    try:
        return float(value)
    except (ValueError, TypeError):
        return default


def clamp(value, low, high):
    """Constrain value to the inclusive [low, high] range."""
    if value < low:
        return low
    if value > high:
        return high
    return value


def round_to(value, digits=1):
    """Round, tolerating non-numeric input (returns None on failure)."""
    try:
        return round(float(value), digits)
    except (ValueError, TypeError):
        return None
