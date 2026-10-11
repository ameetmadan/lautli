import re
import uuid
from collections.abc import Callable
import math


def _key(text: str) -> str:
    return " ".join(re.findall(r"[\w]+", text.casefold(), flags=re.UNICODE))


def has_audio_energy(samples: list[float], threshold: float = 0.0025) -> bool:
    if not samples:
        return False
    rms = math.sqrt(sum(float(sample) ** 2 for sample in samples) / len(samples))
    return rms >= threshold


class StreamingTranscriber:
    def __init__(self, session_id: str, recognize: Callable[[list[float]], list[dict]]):
        self.session_id = session_id
        self.recognize = recognize
        self._pending: dict[tuple[str, str], dict] = {}
        self._committed: list[tuple[str, str, int, int]] = []
        self._window_number = 0

    def process(self, window_start_ms: int, samples: list[float], source: str = "meetingOutput") -> list[dict]:
        self._window_number += 1
        events = [{"type": "status", "state": "transcribing", "message": "Transcribing locally"}]
        for segment in self.recognize(samples):
            text = str(segment["text"]).strip()
            if not text:
                continue
            start = window_start_ms + int(segment["start_ms"])
            end = window_start_ms + int(segment["end_ms"])
            key = _key(text)
            source_key = (source, key)
            if any(committed_source == source and committed_key == key and abs(committed_start - start) <= 2_000
                   for committed_source, committed_key, committed_start, _ in self._committed):
                continue
            candidate = self._pending.get(source_key)
            if candidate and candidate["window_number"] < self._window_number and abs(candidate["start_ms"] - start) <= 2_000:
                segment_id = candidate["id"]
                self._pending.pop(source_key, None)
                self._committed.append((source, key, candidate["start_ms"], max(candidate["end_ms"], end)))
                events.append({"type": "segment", "session_id": self.session_id, "segment": {
                    "id": segment_id, "start_ms": candidate["start_ms"], "end_ms": max(candidate["end_ms"], end),
                    "text": text, "stability": "final", "source": source,
                }})
            else:
                segment_id = str(uuid.uuid4())
                self._pending[source_key] = {"id": segment_id, "start_ms": start, "end_ms": end, "text": text, "window_number": self._window_number}
                events.append({"type": "segment", "session_id": self.session_id, "segment": {
                    "id": segment_id, "start_ms": start, "end_ms": end,
                    "text": text, "stability": "provisional", "source": source,
                }})
        return events

    def flush(self) -> list[dict]:
        events = []
        for (source, _), segment in self._pending.items():
            events.append({"type": "segment", "session_id": self.session_id, "segment": {
                "id": segment["id"], "start_ms": segment["start_ms"], "end_ms": segment["end_ms"],
                "text": segment["text"], "stability": "final", "source": source,
            }})
        self._committed.extend(
            (source, key, segment["start_ms"], segment["end_ms"])
            for (source, key), segment in self._pending.items()
        )
        self._pending.clear()
        return events
