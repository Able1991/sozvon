"""Speaker embeddings through ONNX Runtime on the CPU, for pyannote's diarization on Windows.

The same ResNet, exported to ONNX: the embeddings and the resulting turns match torch, about 40 % faster on the CPU.
Everything around the embeddings stays pyannote's. Only used on the CPU, only when the file is there; on any failure the
diarization starts over on torch.
"""
import sys
from pathlib import Path

from . import config, models, paths, platform_support
from .i18n import t

_given_up = False


def file_path() -> Path | None:
    """The model file, on Windows, when the install has it."""
    if platform_support.SYSTEM != "win32" or _given_up:
        return None
    entry = models.MANIFEST["embedding_onnx"]
    path = paths.data_dir() / "models" / entry["dir"] / entry["file"]
    return path if path.is_file() else None


class OnnxEmbedding:
    """Stands in for pipeline._embedding: fbank features from pyannote's model, the ResNet from the ONNX file."""

    def __init__(self, original, session):
        self._model = original.model_
        self._session = session
        self.sample_rate = original.sample_rate
        self.dimension = original.dimension
        self.metric = original.metric
        self.min_num_samples = original.min_num_samples

    def to(self, device):
        return self

    def __call__(self, waveforms, masks):
        import numpy as np
        import torch
        with torch.inference_mode():
            fbank = self._model.compute_fbank(waveforms)
        return self._session.run(None, {"fbank": fbank.numpy().astype(np.float32),
                                        "weights": masks.numpy().astype(np.float32)})[0]


def _session(path: Path):
    import onnxruntime
    options = onnxruntime.SessionOptions()
    options.intra_op_num_threads = config.load().threads or platform_support.default_thread_limit()
    options.inter_op_num_threads = 1
    options.add_session_config_entry("session.intra_op.allow_spinning", "0")
    return onnxruntime.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])


def give_up(error) -> None:
    """The rest of this process runs on torch."""
    global _given_up
    _given_up = True
    print(t("log_onnx_embedding_failed", err=" ".join(str(error).split())[:300]), file=sys.stderr, flush=True)


def install_on(pipeline) -> None:
    """Swap pipeline's embedding step for the ONNX one, if the file is there. A file that does not load changes nothing."""
    path = file_path()
    if path is None:
        return
    try:
        pipeline._embedding = OnnxEmbedding(pipeline._embedding, _session(path))
    except Exception as e:  # noqa: BLE001  whatever a broken file raises, torch does the work
        give_up(e)


def is_active(pipeline) -> bool:
    return isinstance(getattr(pipeline, "_embedding", None), OnnxEmbedding)
