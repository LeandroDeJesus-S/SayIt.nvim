import argparse
import asyncio
import os
import struct
import warnings
from contextlib import asynccontextmanager
from pathlib import Path

import numpy as np
import onnxruntime as rt
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

warnings.filterwarnings("ignore")

from kokoro_onnx import Kokoro
from kokoro_onnx.trim import trim as trim_audio

# noqa: E402

kokoro: Kokoro | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global kokoro  # noqa: PLW0603
    if not Path(model_path).exists():
        raise RuntimeError(
            f"Model not found at {model_path}. "
            "Download: wget https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
        )
    if not Path(voices_path).exists():
        raise RuntimeError(
            f"Voices not found at {voices_path}. "
            "Download: wget https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"
        )

    # Limit CPU usage by restricting ONNX Runtime threads
    options = rt.SessionOptions()
    options.intra_op_num_threads = int(os.environ.get("INTRA_OP_THREADS", "1"))
    options.inter_op_num_threads = int(os.environ.get("INTER_OP_THREADS", "1"))

    session = rt.InferenceSession(
        model_path, sess_options=options, providers=["CPUExecutionProvider"]
    )
    kokoro = Kokoro.from_session(session, voices_path)

    yield


app = FastAPI(title="Kokoro TTS API", lifespan=lifespan)

model_path = os.environ.get("KOKORO_MODEL_PATH", "kokoro-v1.0.onnx")
voices_path = os.environ.get("KOKORO_VOICES_PATH", "voices-v1.0.bin")


class TTSRequest(BaseModel):
    text: str = Field(..., min_length=1, description="Text to synthesize to speech")
    voice: str = Field(
        default="af_bella", description="Voice name (see /voices endpoint)"
    )
    speed: float = Field(
        default=1.0, ge=0.5, le=2.0, description="Speech speed (0.5 to 2.0)"
    )
    lang: str = Field(default="en-us", description="Language code (en-us, en-gb, etc.)")


class VoicesResponse(BaseModel):
    voices: list[str]


@app.get("/")
def health() -> str:
    return "healthy"


def generate_streaming_wav_header(sample_rate: int, channels: int) -> bytes:
    """
    Generates a WAV (RIFF) header specifically designed for audio streaming.
    """
    bits_per_sample = 32
    byte_rate = sample_rate * channels * bits_per_sample // 8
    block_align = channels * bits_per_sample // 8

    # RIFF chunk
    header = b"RIFF"
    header += struct.pack("<I", 0xFFFFFFFF)  # ChunkSize (placeholder)
    header += b"WAVE"

    # fmt chunk
    header += b"fmt "
    # CHANGE: 18 instead of 16 for IEEE Float
    header += struct.pack("<I", 18)
    header += struct.pack("<H", 0x0003)  # AudioFormat (3 for IEEE Float)
    header += struct.pack("<H", channels)
    header += struct.pack("<I", sample_rate)
    header += struct.pack("<I", byte_rate)
    header += struct.pack("<H", block_align)
    header += struct.pack("<H", bits_per_sample)
    # ADDITION: cbSize (extra format bytes, 0 for standard float32)
    header += struct.pack("<H", 0)

    # data chunk
    header += b"data"
    header += struct.pack("<I", 0xFFFFFFFF)  # Subchunk2Size (placeholder)

    return header


async def generate_streaming_audio(request_data: TTSRequest, request: Request):
    """
    An async generator that yields audio chunks from the Kokoro model.
    Re-implemented here to ensure proper cancellation and low CPU usage.
    """
    if kokoro is None:
        return

    if not request_data.text.strip():
        return

    # Phonemize the text
    phonemes = kokoro.tokenizer.phonemize(request_data.text, request_data.lang)
    # Split into batches
    batched_phonemes = kokoro._split_phonemes(phonemes)

    # Get voice style
    voice = kokoro.get_voice_style(request_data.voice)

    header_sent = False
    loop = asyncio.get_running_loop()

    try:
        for p in batched_phonemes:
            if await request.is_disconnected():
                print("Client disconnected, stopping generation.")
                break

            # Process one batch at a time
            # We use run_in_executor to not block the event loop
            audio_part, sample_rate = await loop.run_in_executor(
                None, kokoro._create_audio, p, voice, request_data.speed
            )

            # Trim silence (optional but recommended for natural sound)
            audio_part, _ = trim_audio(audio_part)

            if not header_sent:
                channels = 1 if audio_part.ndim == 1 else audio_part.shape[1]
                yield generate_streaming_wav_header(sample_rate, channels)
                header_sent = True

            yield audio_part.astype(np.float32).tobytes()

    except Exception as e:
        print(f"Error in streaming audio: {e}")
        return


@app.post("/tts")
async def stream_speech(
    request_data: TTSRequest, request: Request
) -> StreamingResponse:
    """
    Streams synthesized speech back to the client in real-time.

    This endpoint reduces first-byte latency significantly by yielding
    audio chunks as they are produced by the model. It uses a customized
    WAV header to support early playback in most standard audio players.
    """
    if kokoro is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    if not request_data.text.strip():
        raise HTTPException(status_code=400, detail="Text cannot be empty")

    return StreamingResponse(
        generate_streaming_audio(request_data, request),
        media_type="audio/wav",
        headers={
            "Content-Disposition": 'attachment; filename="speech.wav"',
            "Cache-Control": "no-cache",
        },
    )


@app.get("/voices", response_model=VoicesResponse)
async def list_voices() -> VoicesResponse:
    """
    Returns a list of all available voice names.

    These names can be used in the 'voice' field of TTS requests.
    The list is retrieved directly from the loaded Kokoro model.
    """
    if kokoro is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    return VoicesResponse(voices=kokoro.get_voices())


if __name__ == "__main__":
    program = argparse.ArgumentParser()
    program.add_argument(
        "--host",
        type=str,
        default="0.0.0.0",
        help="Host to listen on (default: 0.0.0.0)",
    )
    program.add_argument(
        "--port",
        type=int,
        default=8000,
        help="Port to listen on (default: 8000)",
    )
    program.add_argument(
        "--model-path",
        type=str,
        default=os.environ.get("KOKORO_MODEL_PATH", "kokoro-v1.0.onnx"),
        help="Path to Kokoro model file (default: kokoro-v1.0.onnx)",
    )
    program.add_argument(
        "--voices-path",
        type=str,
        default=os.environ.get("KOKORO_VOICES_PATH", "voices-v1.0.bin"),
        help="Path to Kokoro voices file (default: voices-v1.0.bin)",
    )
    args = program.parse_args()

    model_path = args.model_path
    voices_path = args.voices_path
    uvicorn.run(app, host=args.host, port=args.port)
