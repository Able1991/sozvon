"""ffmpeg: decoding to 16 kHz mono and wav preparation. All engine ffmpeg calls live here."""
import os
import subprocess
import tempfile
from pathlib import Path

SR = 16000

# Formats mlx-whisper reads directly. Any video CONTAINER (and .webm) goes to
# VIDEO_EXTS: audio is extracted to wav once, then Whisper and pyannote both read that file.
AUDIO_EXTS = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".opus", ".aac", ".aiff", ".aif", ".caf"}
VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".avi", ".m4v", ".webm", ".flv", ".wmv", ".ts", ".mts", ".3gp"}


class FfmpegError(RuntimeError):
    """ffmpeg failed to read or write the file (corrupted recording)."""

    def __init__(self, file, detail: str = ""):
        super().__init__(f"{file}: {detail}".strip(": "))
        self.file = Path(file)
        self.detail = detail


class FfmpegMissing(RuntimeError):
    """ffmpeg not found: the engine environment is not built."""


def _run(args: list, src) -> bytes:
    try:
        r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", *args], capture_output=True)
    except FileNotFoundError as e:
        raise FfmpegMissing("ffmpeg") from e
    if r.returncode != 0:
        raise FfmpegError(src, r.stderr.decode("utf-8", "replace").strip()[-300:])
    return r.stdout


def decode(path) -> "np.ndarray":  # noqa: F821
    """Any file -> 16 kHz mono float32."""
    import numpy as np
    raw = _run(["-i", str(path), "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"], path)
    return np.frombuffer(raw, dtype=np.float32)


def decode_span(path, start: float, duration: float) -> "np.ndarray":  # noqa: F821
    """A piece of a file -> 16 kHz mono float32, without decoding the rest (low memory on long calls)."""
    import numpy as np
    raw = _run(["-ss", f"{max(0.0, start):.3f}", "-t", f"{max(0.0, duration):.3f}", "-i", str(path),
                "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"], path)
    return np.frombuffer(raw, dtype=np.float32)


def duration(path) -> float:
    """Length of a file in seconds, from ffmpeg's header line (nothing is decoded)."""
    import re
    try:
        r = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-i", str(path)], capture_output=True)
    except FileNotFoundError as e:
        raise FfmpegMissing("ffmpeg") from e
    m = re.search(r"Duration: (\d+):(\d{2}):(\d{2}(?:\.\d+)?)", r.stderr.decode("utf-8", "replace"))
    if not m:
        raise FfmpegError(path, "no duration")
    h, mi, sec = m.groups()
    return int(h) * 3600 + int(mi) * 60 + float(sec)


def to_wav(src: Path, dst: Path, delay: float = 0.0) -> Path:
    """Track -> 16 kHz mono wav, with a start offset to sync tracks."""
    af = ["-af", f"adelay={int(delay * 1000)}:all=1"] if delay > 0.01 else []
    _run(["-y", "-i", str(src), *af, "-ac", "1", "-ar", str(SR), str(dst)], src)
    return dst


def to_m4a(src: Path, dst: Path) -> Path:
    """wav -> AAC m4a (for listening), written to a hidden temp file and renamed into place."""
    tmp = dst.with_name(f".{dst.stem}.tmp.m4a")
    try:
        _run(["-y", "-i", str(src), "-c:a", "aac", "-b:a", "48k", str(tmp)], src)
        os.replace(tmp, dst)
    finally:
        Path(tmp).unlink(missing_ok=True)
    return dst


def extract_audio(video: Path) -> Path:
    """Audio from a video into a temporary 16 kHz wav (the caller deletes it)."""
    fd, out = tempfile.mkstemp(prefix=f"{video.stem}_", suffix=".wav")
    os.close(fd)
    return to_wav(video, Path(out))
