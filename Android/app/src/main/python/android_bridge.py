"""Android adapter. The upload engine is sourced directly from ../../Bridge by Gradle."""
import json
import logging
import gpmc_bridge as bridge
# Never write auth responses, cookies or local file names to Android logcat.
logging.disable(logging.CRITICAL)
def run(payload, listener, cancellation):
    stop = bridge.StopSignal()
    def emit(event):
        # Confirmations are persisted before observing cancellation.
        listener.event(json.dumps(event))
        if cancellation.get():
            stop.request()
    if cancellation.get():
        return bridge.EXIT_STOPPED
    return bridge.run(json.loads(payload), emit, stop=stop)


def initialize():
    """Load pinned gpmc without its CLI-only SIGINT process handler.

    gpmc 0.9.0 resets SIGINT at module import for terminal Ctrl+C. Android
    workers have no terminal and Chaquopy rejects signal registration from a
    Java worker thread. Suppress exactly that upstream reset during the eager,
    app-startup import; retain signal.signal unchanged for all other callers.
    WorkManager cancellation is handled by StopSignal, not process signals.
    """
    import signal
    import sys
    import importlib.metadata
    if importlib.metadata.version("gpmc") != "0.9.0":
        raise RuntimeError("Recheck Android signal compatibility for this gpmc version")
    original = signal.signal
    def android_signal(number, handler):
        caller = sys._getframe(1).f_globals.get("__name__")
        if caller == "gpmc.client" and number == signal.SIGINT and handler == signal.SIG_DFL:
            return signal.getsignal(number)
        return original(number, handler)
    signal.signal = android_signal
    try:
        import gpmc
    finally:
        signal.signal = original
