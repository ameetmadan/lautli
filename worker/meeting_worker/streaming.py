import re
import uuid
from collections.abc import Callable


def _key(text: str) -> str:
    return " ".join(re.findall(r"[\w]+", text.casefold(), flags=re.UNICODE))


class StreamingTranscriber:
    def __init__(self, session_id: str, recognize: Callable[[list[float]], list[dict]]):
        self.session_id = session_id
        self.recognize = recognize
        self._pending: dict[str, dict] = {}
        self._committed: set[str] = set()
        self._window_number = 0

    def process(self, window_start_ms: int, samples: list[float]) -> list[dict]:
        self._window_number += 1
        events = [{"type": "status", "state": "transcribing", "message": "Transcribing locally"}]
        for segment in self.recognize(samples):
            text = str(segment["text"]).strip()
            if not text:
                continue
            start = window_start_ms + int(segment["start_ms"])
            end = window_start_ms + int(segment["end_ms"])
            key = _key(text)
            if key in self._committed:
                continue
            candidate = self._pending.get(key)
            if candidate and candidate["window_number"] < self._window_number and abs(candidate["start_ms"] - start) <= 8_000:
                segment_id = candidate["id"]
                self._pending.pop(key, None)
                self._committed.add(key)
                events.append({"type": "segment", "session_id": self.session_id, "segment": {
                    "id": segment_id, "start_ms": candidate["start_ms"], "end_ms": max(candidate["end_ms"], end),
                    "text": text, "stability": "final",
                }})
            else:
                segment_id = str(uuid.uuid4())
                self._pending[key] = {"id": segment_id, "start_ms": start, "end_ms": end, "window_number": self._window_number}
                events.append({"type": "segment", "session_id": self.session_id, "segment": {
                    "id": segment_id, "start_ms": start, "end_ms": end,
                    "text": text, "stability": "provisional",
                }})
        return events
