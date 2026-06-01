"""common.log -- centralized logger access.

Wraps system.util.getLogger so every layer logs under a consistent
'example.<name>' namespace. Filter on 'example' in the Gateway logs to see
everything this project emits.

    from common import log
    logger = log.get("application.refrigeration")
    logger.info("evaluated %d units" % count)
"""

# Jython 2.7 (Ignition). No f-strings; use % or .format().

_PREFIX = "example"


def get(name):
    """Return a named logger under the project's 'example.' namespace.

    Args:
        name: dotted suffix, e.g. "infrastructure.tags".

    Returns:
        A LoggerEx (the object system.util.getLogger returns).
    """
    return system.util.getLogger("%s.%s" % (_PREFIX, name))
