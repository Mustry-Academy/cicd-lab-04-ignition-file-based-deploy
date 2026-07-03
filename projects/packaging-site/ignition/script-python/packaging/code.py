"""packaging -- tiny helper library for the packaging-site project.

Deliberately minimal and side-effect free. This project exists to demonstrate
that the file-based deploy ships *every* project under projects/, not just one.
Re-theme freely.
"""

# Jython 2.7 (Ignition).


def line_state_label(running):
    """Return a human-readable line state for the overview header.

    Kept trivial on purpose; the point of this project is the deploy path, not
    the logic.
    """
    return "Line state: running" if running else "Line state: idle"
