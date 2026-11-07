"""Sozvon engine: local call transcription (mlx-whisper, pyannote, onnx-asr).

The package has no import side effects: heavy libraries load lazily, and the process
environment is set up by runtime.prepare() in the entry points (server.py, bin/*.py, install.py).
The app contract is described in docs/CONTRACT.md.
"""
