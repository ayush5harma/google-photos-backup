"""Deterministic synthetic backend: DEBUG SOURCE SET ONLY."""
import json
from types import SimpleNamespace
import gpmc_bridge as bridge

def run(payload, listener, cancellation, mode):
    stop = bridge.StopSignal()
    def emit(event):
        listener.event(json.dumps(event))
        if cancellation.get(): stop.request()
    class Client:
        api = SimpleNamespace(bearer_token="synthetic-not-a-credential")
        def upload(self, target, progress_callback, **kwargs):
            path = next(iter(target))
            if mode == "cancel": cancellation.set(True)
            progress_callback({"path":path.as_posix(),"phase":"upload","bytes_completed":2,"bytes_total":4})
            return {} if mode == "failure" else {path.as_posix():"synthetic-media-key"}
    return bridge.run(json.loads(payload), emit, client_factory=lambda auth,timeout:Client(), stop=stop)
