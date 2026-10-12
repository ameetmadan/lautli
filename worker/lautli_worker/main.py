import os
import sys
from typing import TextIO

import numpy as np
from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor, pipeline

from scripts.asr_probe import segment_records
from worker.lautli_worker.cleanup import apply_replacements, collapse_repetitions, is_hallucination, parse_vocabulary
from worker.lautli_worker.device import pick_device
from worker.lautli_worker.model_spec import MODEL_ID, MODEL_REVISION
from worker.lautli_worker.protocol import AudioWindow, ProtocolError, Stop, encode_message, parse_message
from worker.lautli_worker.streaming import StreamingTranscriber, has_audio_energy


def load_recognizer():
    model_path = os.environ.get("WHISPER_MODEL_PATH", ".models/flix-swissgerman-full")
    print(encode_message({"type": "status", "state": "loading", "message": "Loading local Swiss German model"}), end="", flush=True)
    device, dtype = pick_device()
    processor = AutoProcessor.from_pretrained(model_path, local_files_only=True)
    model = AutoModelForSpeechSeq2Seq.from_pretrained(
        model_path, dtype=dtype, low_cpu_mem_usage=True, use_safetensors=True, local_files_only=True,
    ).to(device)
    recognizer = pipeline(
        "automatic-speech-recognition", model=model, tokenizer=processor.tokenizer,
        feature_extractor=processor.feature_extractor, dtype=dtype, device=device,
    )

    vocabulary_file = os.environ.get("LAUTLI_VOCABULARY_FILE", "")
    terms, replacements = parse_vocabulary(open(vocabulary_file, encoding="utf-8").read()) if os.path.isfile(vocabulary_file) else ([], {})
    generate_kwargs = {
        "language": "german", "task": "transcribe",
        # Retry hotter when a decode loops or is low-confidence, and never feed a bad decode into the next one.
        "temperature": (0.0, 0.2, 0.4, 0.6, 0.8, 1.0), "compression_ratio_threshold": 1.35,
        "logprob_threshold": -1.0, "no_speech_threshold": 0.6, "condition_on_prev_tokens": False,
    }
    if terms:
        generate_kwargs["prompt_ids"] = processor.get_prompt_ids(", ".join(dict.fromkeys(terms)), return_tensors="pt").to(device)

    def recognize(samples: list[float]) -> list[dict]:
        if not has_audio_energy(samples):
            return []
        result = recognizer(
            {"raw": np.asarray(samples, dtype=np.float32), "sampling_rate": 16_000},
            chunk_length_s=30, stride_length_s=(5, 5), return_timestamps=True, generate_kwargs=generate_kwargs,
        )
        segments = []
        for segment in segment_records(result):
            if is_hallucination(segment["text"]):
                continue
            segment["text"] = apply_replacements(collapse_repetitions(segment["text"]), replacements)
            segments.append(segment)
        return segments

    return recognize


def serve(input_stream: TextIO, output_stream: TextIO, recognize) -> int:
    def emit(value):
        output_stream.write(encode_message(value))
        output_stream.flush()

    emit({"type": "status", "state": "ready", "message": f"{MODEL_ID} ({MODEL_REVISION[:12]}) ready locally"})
    session_id = None
    transcriber = None
    for line in input_stream:
        try:
            message = parse_message(line)
        except ProtocolError as error:
            emit({"type": "status", "state": "failed", "message": str(error)})
            return 2
        if isinstance(message, Stop):
            if session_id is not None and session_id != message.session_id:
                emit({"type": "status", "state": "failed", "message": "Session ID mismatch"})
                return 2
            if transcriber:
                for event in transcriber.flush():
                    emit(event)
            session_id = None
            transcriber = None
            emit({"type": "status", "state": "ready", "message": "Transcription stopped"})
            continue
        if session_id is None:
            session_id = message.session_id
            transcriber = StreamingTranscriber(session_id, recognize)
        if message.session_id != session_id or not isinstance(message, AudioWindow):
            emit({"type": "status", "state": "failed", "message": "Session ID mismatch"})
            return 2
        samples = np.frombuffer(message.samples, dtype="<f4").astype(np.float32, copy=False).tolist()
        for event in transcriber.process(message.start_ms, samples, message.source):
            emit(event)
    return 0


def run() -> int:
    try:
        recognize = load_recognizer()
    except Exception as error:
        print(encode_message({"type": "status", "state": "failed", "message": f"Local model failed to load: {type(error).__name__}"}), end="", flush=True)
        return 1
    return serve(sys.stdin, sys.stdout, recognize)


if __name__ == "__main__":
    raise SystemExit(run())
