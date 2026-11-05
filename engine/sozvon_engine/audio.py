"""ffmpeg: декодирование в 16 кГц mono и подготовка wav. Все вызовы ffmpeg движка здесь."""
import os
import subprocess
import tempfile
from pathlib import Path

SR = 16000

# Форматы, которые mlx-whisper читает напрямую. Любой видео-КОНТЕЙНЕР (и .webm) идёт в
# VIDEO_EXTS: звук вытаскивается в wav один раз, и Whisper и pyannote читают уже готовый файл.
AUDIO_EXTS = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".opus", ".aac", ".aiff", ".aif", ".caf"}
VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".avi", ".m4v", ".webm", ".flv", ".wmv", ".ts", ".mts", ".3gp"}


class FfmpegError(RuntimeError):
    """ffmpeg не смог прочитать или записать файл (повреждённая запись)."""

    def __init__(self, file, detail: str = ""):
        super().__init__(f"{file}: {detail}".strip(": "))
        self.file = Path(file)
        self.detail = detail


class FfmpegMissing(RuntimeError):
    """ffmpeg не найден: окружение движка не собрано."""


def _run(args: list, src) -> bytes:
    try:
        r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", *args], capture_output=True)
    except FileNotFoundError as e:
        raise FfmpegMissing("ffmpeg") from e
    if r.returncode != 0:
        raise FfmpegError(src, r.stderr.decode("utf-8", "replace").strip()[-300:])
    return r.stdout


def decode(path) -> "np.ndarray":  # noqa: F821
    """Любой файл -> 16 кГц mono float32."""
    import numpy as np
    raw = _run(["-i", str(path), "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"], path)
    return np.frombuffer(raw, dtype=np.float32)


def to_wav(src: Path, dst: Path, delay: float = 0.0) -> Path:
    """Дорожка -> 16 кГц mono wav, со сдвигом начала для синхронизации дорожек."""
    af = ["-af", f"adelay={int(delay * 1000)}:all=1"] if delay > 0.01 else []
    _run(["-y", "-i", str(src), *af, "-ac", "1", "-ar", str(SR), str(dst)], src)
    return dst


def extract_audio(video: Path) -> Path:
    """Звук из видео во временный 16 кГц wav (удаляет вызывающий)."""
    fd, out = tempfile.mkstemp(prefix=f"{video.stem}_", suffix=".wav")
    os.close(fd)
    return to_wav(video, Path(out))
