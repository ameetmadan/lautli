import os
import sys

import numpy as np
import torch
from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor, pipeline

from scripts.asr_probe import MODEL_ID, MODEL_REVISION, segment_records
from worker.meeting_worker.protocol import AudioWindow, ProtocolError, Stop, encode_message, parse_message
from worker.meeting_worker.streaming import StreamingTranscriber


def load_recognizer():
    model_path = os.environ.get("WHISPER_MODEL_PATH", ".models/flix-swissgerman-full")
    print(encode_message({"type": "status", "state": "loading", "message": "Loading local Swiss German model"}), end="", flush=True)
    processor = AutoProcessor.from_pretrained(model_path, local_files_only=True)
    model = AutoModelForSpeechSeq2Seq.from_pretrained(
        model_path, dtype=torch.float16, low_cpu_mem_usage=True, use_safetensors=True, local_files_only=True,
    ).to("mps")
    recognizer = pipeline(
        "automatic-speech-recognition", model=model, tokenizer=processor.tokenizer,
        feature_extractor=processor.feature_extractor, dtype=torch.float16, device="mps",
    )

    def recognize(samples: list[float]) -> list[dict]:
        result = recognizer(
            {"raw": np.asarray(samples, dtype=np.float32), "sampling_rate": 16_000},
            chunk_length_s=30, stride_length_s=(5, 5), return_timestamps=True,
            generate_kwargs={"language": "german", "task": "transcribe"},
        )
        return segment_records(result)

    return recognize


def run() -> int:
    try:
        recognize = load_recognizer()
    except Exception as error:
        print(encode_message({"type": "status", "state": "failed", "message": f"Local model failed to load: {type(error).__name__}"}), end="", flush=True)
        return 1
    print(encode_message({"type": "status", "state": "ready", "message": f"{MODEL_ID} ({MODEL_REVISION[:12]}) ready locally"}), end="", flush=True)
    session_id = None
    transcriber = None
    for line in sys.stdin:
        try:
            message = parse_message(line)
        except ProtocolError as error:
            print(encode_message({"type": "status", "state": "failed", "message": str(error)}), end="", flush=True)
            return 2
        if isinstance(message, Stop):
            if session_id != message.session_id:
                print(encode_message({"type": "status", "state": "failed", "message": "Session ID mismatch"}), end="", flush=True)
                return 2
            print(encode_message({"type": "status", "state": "ready", "message": "Transcription stopped"}), end="", flush=True)
            return 0
        if session_id is None:
            session_id = message.session_id
            transcriber = StreamingTranscriber(session_id, recognize)
        if message.session_id != session_id or not isinstance(message, AudioWindow):
            print(encode_message({"type": "status", "state": "failed", "message": "Session ID mismatch"}), end="", flush=True)
            return 2
        samples = np.frombuffer(message.samples, dtype="<f4").astype(np.float32, copy=False).tolist()
        for event in transcriber.process(message.start_ms, samples):
            print(encode_message(event), end="", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
