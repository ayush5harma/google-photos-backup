"""Android adapter. The upload engine is sourced directly from ../../Bridge by Gradle."""
import json
import logging
import threading
import gpmc_bridge as bridge
# Never write auth responses, cookies or local file names to Android logcat.
logging.disable(logging.CRITICAL)


def _run(payload, listener, cancellation, **factory):
    stop = bridge.StopSignal()
    stopped = threading.Event()
    request_thread = threading.current_thread()
    def emit(event):
        # On a stop the bridge drops files not yet started, but its threads
        # already uploading would carry on: in a separate bridge process they
        # die with it, here they share the app's process and would send to the
        # end, unheard, after Cancel. gpmc 0.9.0 reports progress while it
        # streams a file and just before its commit, and catches only
        # Exception there, so a StopRequested from any later emit ends that
        # upload at its next report (issue #59 review). The request's own
        # thread still reports the bridge's closing "stopped" event.
        if stopped.is_set() and threading.current_thread() is not request_thread:
            raise bridge.StopRequested
        # Confirmations are persisted before observing cancellation.
        listener.event(json.dumps(event))
        if cancellation.get():
            try:
                stop.request()
            except bridge.StopRequested:
                stopped.set()
                raise
    if cancellation.get():
        return bridge.EXIT_STOPPED
    return bridge.run(json.loads(payload), emit, stop=stop, **factory)


def run(payload, listener, cancellation):
    """One request with a client of its own (sign-in and connections included)."""
    return _run(payload, listener, cancellation)


class Session:
    """One BackupWorker run (issue #59): one gpmc client, its bearer token and
    the bridge's kept connections serve every request of the run, as the Mac
    app's serve session does, instead of a sign-in and four new TLS
    connections per file. bridge.ClientCache is the serve session's own
    factory; because it keeps clients, bridge.run routes gpmc's calls through
    the client's session pool and leaves the client open between requests.
    The worker calls close() when it ends, which closes the pool. One request
    at a time: the worker sends them in turn from its own thread."""

    def __init__(self, client_factory=None):
        self._clients = bridge.ClientCache(client_factory or bridge.default_client_factory)

    def run(self, payload, listener, cancellation):
        return _run(payload, listener, cancellation, client_factory=self._clients)

    def close(self):
        self._clients.close()


def session(client_factory=None):
    return Session(client_factory)


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
