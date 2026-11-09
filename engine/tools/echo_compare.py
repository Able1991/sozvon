"""Compare echo removal between machines and devices, on identical input.

Not part of the test suite: nothing here runs or downloads anything during a normal test run.

  build    make a synthetic call (mic.m4a, system.m4a, clean.wav, labels.json) from two speech recordings
  run      run the engine's echo removal on it and save the result as lossless WAV
  metrics  residual echo, near-end speech loss and SI-SDR of one output WAV
  compare  compare two output WAVs sample by sample, with the metrics side by side

Exit codes: 0 done; 1 the step failed (ffmpeg, network, the engine removed no echo); 2 bad arguments or input.
"""
import argparse
import hashlib
import json
import math
import shutil
import sys
import tempfile
import time
import urllib.request
import wave
from dataclasses import asdict, dataclass, replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sozvon_engine import runtime  # noqa: E402

runtime.prepare()  # before numpy: it sets the engine's thread limits

import numpy as np  # noqa: E402

from sozvon_engine import accel, audio  # noqa: E402
from sozvon_engine.i18n import t  # noqa: E402
from sozvon_engine.pipeline import tracks  # noqa: E402

SR = audio.SR


@dataclass(frozen=True)
class Recording:
    file: str
    url: str
    sha256: str
    credit: str


# LibriVox recordings are in the public domain; archive.org marks these two with the Public Domain Mark 1.0
# (near) and the Creative Commons public domain license (far).
NEAR = Recording(
    "veshniyevody_01_turgenev_64kb.mp3",
    "https://archive.org/download/veshnie_vody_1607_librivox/veshniyevody_01_turgenev_64kb.mp3",
    "0310d776204574de64960963b222108697c2a652b8392ffad46bbeb94c626f09",
    "Ivan Turgenev, Veshnie vody, chapter 1, read in Russian by tovarisch (LibriVox)")
FAR = Recording(
    "art_of_war_03-04_sun_tzu_64kb.mp3",
    "https://archive.org/download/art_of_war_librivox/art_of_war_03-04_sun_tzu_64kb.mp3",
    "57e879fe7822578fd22010f1280185799a119a3482e025d9a71f49878ff45ba7",
    "Sun Tzu, The Art of War, chapters 3-4, read in English by Moira Fogarty (LibriVox)")


@dataclass(frozen=True)
class Scene:
    seed: int = 20261109
    seconds: float = 120.0
    skip_seconds: float = 30.0   # past the spoken LibriVox introduction
    # (kind, seconds), repeated up to `seconds`. One cycle holds every kind of stretch.
    cycle: tuple = (("pause", 1.0), ("far", 7.0), ("pause", 1.0), ("near", 6.0),
                    ("pause", 1.0), ("double", 6.0), ("far", 5.0), ("near", 3.0))
    fade_ms: int = 10
    near_level: float = 0.40     # 99.5th percentile of |sample| while speaking, full scale = 1
    far_level: float = 0.35
    echo_level: float = 0.30
    clip_ratio: float = 0.80     # the echo is clipped at this fraction of echo_level
    noise_rms: float = 0.0018    # about -55 dBFS, added to the microphone only
    rir_ms: int = 200
    rt60_ms: int = 250
    reflections: float = 0.4     # level of the decaying tail against the direct path
    base_delay_ms: int = 200
    jumps_ms: tuple = (-90, 250)
    jumps_at: tuple = (0.40, 0.75)   # as a fraction of `seconds`
    frame_ms: int = 20           # metrics frames
    guard_seconds: float = 0.7   # skipped at the start of a stretch: the echo tail of the one before
    active_rms: float = 0.005    # a frame this loud has speech in it


SCENE = Scene()
MIC, SYSTEM, CLEAN, LABELS = "mic.m4a", "system.m4a", "clean.wav", "labels.json"


class InputProblem(Exception):
    """Bad arguments or input: exit code 2."""


class StepFailed(Exception):
    """The step ran and did not succeed: exit code 1."""


# ---------------------------------------------------------------- files


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def download(rec: Recording, path: Path) -> None:
    part = path.with_name(path.name + ".part")
    path.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(rec.url, headers={"User-Agent": "sozvon-echo-compare"})
    with urllib.request.urlopen(request, timeout=60) as r, open(part, "wb") as f:  # nosemgrep
        shutil.copyfileobj(r, f)
    if sha256(part) != rec.sha256:
        part.unlink()
        raise StepFailed(f"{rec.url}: the download does not match the pinned SHA-256")
    part.replace(path)


def recording(rec: Recording, cache: Path, allow_download: bool) -> Path:
    path = cache / rec.file
    if not path.is_file():
        if not allow_download:
            raise InputProblem(f"{path} is missing; pass --download to fetch {rec.url}")
        download(rec, path)
    if sha256(path) != rec.sha256:
        raise InputProblem(f"{path} does not match the pinned SHA-256; delete it and pass --download")
    return path


def decode(path: Path, scene: Scene) -> np.ndarray:
    """MP3 -> 16 kHz mono int16 after the intro. The fixed-point decoder and integer resampling, because
    audio.decode() goes through floats, whose last bits depend on the CPU."""
    raw = audio._run(["-c:a", "mp3", "-i", str(path), "-flags:a", "+bitexact", "-f", "s16le", "-ac", "1",
                      "-ar", str(SR), "-"], path)
    return np.frombuffer(raw, "<i2")[int(scene.skip_seconds * SR):]


def write_wav(path: Path, x: np.ndarray) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(np.clip(x, -32768, 32767).astype("<i2").tobytes())


def read_wav(path: Path) -> np.ndarray:
    """16-bit mono 16 kHz WAV -> float64, full scale = 1."""
    if not path.is_file():
        raise InputProblem(f"{path} does not exist")
    with wave.open(str(path), "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, SR):
            raise InputProblem(f"{path}: expected 16 kHz mono 16-bit WAV")
        return np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float64) / 32768.0


def write_m4a(path: Path, x: np.ndarray) -> None:
    """ALAC in .m4a: the engine reads it like any recording, and every machine decodes the same samples
    (AAC would not be lossless, and its encoder is not bit-exact across CPUs)."""
    tmp = path.with_suffix(".tmp.wav")
    try:
        write_wav(tmp, x)
        audio._run(["-y", "-i", str(tmp), "-c:a", "alac", "-fflags", "+bitexact", "-flags:a", "+bitexact",
                    str(path)], tmp)
    finally:
        tmp.unlink(missing_ok=True)


def load_labels(scene_dir: Path) -> dict:
    path = scene_dir / LABELS
    if not path.is_file():
        raise InputProblem(f"{path} does not exist: is this a folder made by build?")
    return json.loads(path.read_text(encoding="utf-8"))


# ---------------------------------------------------------------- build (integer arithmetic: same on any CPU)


def stretches(scene: Scene) -> list:
    out, at = [], 0.0
    while at < scene.seconds:
        for kind, length in scene.cycle:
            end = min(at + length, scene.seconds)
            if end > at:
                out.append({"kind": kind, "start": at, "end": end})
            at = end
    return out


def spans(parts: list, kinds: tuple) -> list:
    """Sample ranges of the stretches of these kinds, neighbours merged."""
    out = []
    for p in parts:
        if p["kind"] not in kinds:
            continue
        a, b = round(p["start"] * SR), round(p["end"] * SR)
        if out and out[-1][1] == a:
            out[-1] = (out[-1][0], b)
        else:
            out.append((a, b))
    return out


def place(src: np.ndarray, ranges: list, n: int, fade: int) -> np.ndarray:
    """Consecutive pieces of a recording into these ranges of a silent track, with short fades."""
    out = np.zeros(n, np.int64)
    ramp = np.rint(np.linspace(0, 32768, fade)).astype(np.int64)
    at = 0
    for a, b in ranges:
        piece = src[at:at + b - a].astype(np.int64)
        if len(piece) < b - a:
            raise InputProblem("the recording is too short for this many seconds")
        piece[:fade] = (piece[:fade] * ramp) >> 15
        piece[-fade:] = (piece[-fade:] * ramp[::-1]) >> 15
        out[a:b] = piece
        at += b - a
    return out


def scale(x: np.ndarray, level: float) -> np.ndarray:
    """Bring the loud parts of the speech to `level`."""
    peak = float(np.percentile(np.abs(x[x != 0]), 99.5))
    return (x * round(level * 32768 / peak * (1 << 15))) >> 15


def room(scene: Scene, rng: np.random.Generator) -> np.ndarray:
    """Impulse response, Q15: the direct path and a decaying noise tail."""
    n = scene.rir_ms * SR // 1000
    decay = np.exp(-6.908 * np.arange(n) / (scene.rt60_ms * SR / 1000))
    h = scene.reflections * rng.standard_normal(n) * decay
    h[0] = 1.0
    return np.rint(h * 32768).astype(np.int64)


def delay_track(scene: Scene, n: int) -> tuple[np.ndarray, list]:
    """-> (echo delay of every sample, labels of the pieces)."""
    samples = np.full(n, scene.base_delay_ms * SR // 1000, np.int64)
    pieces = [{"at": 0.0, "delay_ms": scene.base_delay_ms}]
    for fraction, jump in zip(scene.jumps_at, scene.jumps_ms):
        at = int(fraction * n)
        samples[at:] += jump * SR // 1000
        pieces.append({"at": at / SR, "delay_ms": pieces[-1]["delay_ms"] + jump})
    return samples, pieces


def echo_of(far: np.ndarray, scene: Scene, rng: np.random.Generator, delay: np.ndarray) -> np.ndarray:
    wet = scale(np.convolve(far, room(scene, rng))[:len(far)] >> 15, scene.echo_level)
    limit = round(scene.clip_ratio * scene.echo_level * 32768)
    wet = np.clip(wet, -limit, limit)
    index = np.arange(len(far)) - delay
    return np.where(index >= 0, wet[np.maximum(index, 0)], 0)


def synthesize(near_src: np.ndarray, far_src: np.ndarray, scene: Scene) -> dict:
    n = round(scene.seconds * SR)
    parts = stretches(scene)
    fade = scene.fade_ms * SR // 1000
    near = scale(place(near_src, spans(parts, ("near", "double")), n, fade), scene.near_level)
    far = scale(place(far_src, spans(parts, ("far", "double")), n, fade), scene.far_level)
    rng = np.random.default_rng(scene.seed)
    delay, pieces = delay_track(scene, n)
    echo = echo_of(far, scene, rng, delay)
    noise = np.rint(rng.standard_normal(n) * scene.noise_rms * 32768).astype(np.int64)
    return {"near": near, "far": far, "mic": near + echo + noise, "parts": parts, "delays": pieces}


def build(args) -> int:
    cycle = sum(length for _, length in SCENE.cycle)
    if args.seconds < cycle:
        raise InputProblem(f"--seconds must cover at least one full cycle of the scene ({cycle:g} s)")
    scene = replace(SCENE, seconds=args.seconds)
    near_src = decode(recording(NEAR, args.cache, args.download), scene)
    far_src = decode(recording(FAR, args.cache, args.download), scene)
    made = synthesize(near_src, far_src, scene)
    args.out.mkdir(parents=True, exist_ok=True)
    write_m4a(args.out / MIC, made["mic"])
    write_m4a(args.out / SYSTEM, made["far"])
    write_wav(args.out / CLEAN, made["near"])
    labels = {"sample_rate": SR, "scene": asdict(scene), "near": asdict(NEAR), "far": asdict(FAR),
              "stretches": made["parts"], "delays": made["delays"],
              "sha256": {name: sha256(args.out / name) for name in (MIC, SYSTEM, CLEAN)}}
    # bytes, not text: a text write would put CRLF into the file on Windows
    (args.out / LABELS).write_bytes(json.dumps(labels, indent=1, sort_keys=True).encode("utf-8") + b"\n")
    for name, digest in labels["sha256"].items():
        print(f"{name}  {digest}")
    print(f"{LABELS}  {sha256(args.out / LABELS)}")
    return 0


# ---------------------------------------------------------------- run


def run(args) -> int:
    for name in (MIC, SYSTEM):
        if not (args.scene / name).is_file():
            raise InputProblem(f"{args.scene / name} does not exist: is this a folder made by build?")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    log, warnings, gains = [], [], {}
    with tempfile.TemporaryDirectory(dir=args.out.parent, ignore_cleanup_errors=True) as tmp:
        work = Path(tmp)
        for name in (MIC, SYSTEM):
            shutil.copyfile(args.scene / name, work / name)
        start = time.monotonic()
        ready = tracks.prepare(tracks.track_files(work), tracks.delays({}), work, log.append,
                               lambda step, error: warnings.append(f"{step}: {error}"), gains)
        seconds = time.monotonic() - start
        if "mic" not in ready:
            raise StepFailed("the engine found no speech in the microphone track")
        shutil.copyfile(ready["mic"], args.out)
    neural = t("log_aec_neural") in log
    summary = {"input_sha256": {name: sha256(args.scene / name) for name in (MIC, SYSTEM)},
               "device": accel.torch_device("echo") if neural else "none", "neural": neural,
               "echo_removed": bool(gains.get("mic_echo_free")), "seconds": round(seconds, 2),
               "gains": gains, "log": log, "warnings": warnings}
    args.out.with_suffix(".json").write_text(json.dumps(summary, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{args.out}: device {summary['device']}, neural stage {'ran' if neural else 'did NOT run'}, {seconds:.1f} s")
    for line in log + warnings:
        print(f"  {line}")
    if not summary["echo_removed"]:
        raise StepFailed("the engine left the microphone as it was: no echo was removed")
    return 0


# ---------------------------------------------------------------- metrics


def frame_power(x: np.ndarray, size: int) -> np.ndarray:
    n = len(x) // size
    return (x[:n * size].reshape(n, size) ** 2).mean(axis=1)


def frame_kinds(labels: dict, count: int, frame_s: float, guard: float) -> np.ndarray:
    kinds = np.full(count, "", dtype=object)
    for p in labels["stretches"]:
        kinds[int(math.ceil((p["start"] + guard) / frame_s)):int(p["end"] / frame_s)] = p["kind"]
    return kinds


def db(power: float) -> float:
    return 10 * math.log10(power) if power > 0 else -math.inf


def si_sdr(reference: np.ndarray, estimate: np.ndarray) -> float:
    target = reference * float(estimate @ reference) / float(reference @ reference)
    return db(float(target @ target)) - db(float((estimate - target) @ (estimate - target)))


def score(out: np.ndarray, scene_dir: Path) -> dict:
    """{residual_db, near_loss_db, si_sdr_db}; a metric without frames to measure is None."""
    labels = load_labels(scene_dir)
    clean = read_wav(scene_dir / CLEAN)
    mic = audio.decode(scene_dir / MIC).astype(np.float64)
    length = min(len(out), len(clean), len(mic))
    size = labels["scene"]["frame_ms"] * SR // 1000
    active = labels["scene"]["active_rms"] ** 2
    kinds = frame_kinds(labels, length // size, size / SR, labels["scene"]["guard_seconds"])

    def frames(mask: np.ndarray, x: np.ndarray) -> np.ndarray:
        return x[:len(mask) * size].reshape(-1, size)[mask].ravel()

    speaking = frame_power(clean[:length], size) > active
    far = (kinds == "far") & (frame_power(mic[:length], size) > active)
    near = (kinds == "near") & speaking
    double = (kinds == "double") & speaking
    return {"residual_db": db(float(np.mean(frames(far, out) ** 2))) if far.any() else None,
            "near_loss_db": (db(float(np.mean(frames(near, clean) ** 2))) - db(float(np.mean(frames(near, out) ** 2)))
                             if near.any() else None),
            "si_sdr_db": si_sdr(frames(double, clean), frames(double, out)) if double.any() else None}


METRICS = (("residual_db", "residual in far-end-only frames (dBFS)"),
           ("near_loss_db", "near-end speech loss in near-end-only frames (dB, target 0)"),
           ("si_sdr_db", "SI-SDR in double-talk frames (dB)"))


def number(value) -> str:
    return "n/a" if value is None else f"{value:.2f}"


def metrics(args) -> int:
    result = score(read_wav(args.wav), args.scene)
    for key, title in METRICS:
        print(f"{title}: {number(result[key])}")
    return 1 if any(v is None for v in result.values()) else 0


# ---------------------------------------------------------------- compare


def difference(a: np.ndarray, b: np.ndarray) -> dict:
    d = a - b
    spread = float(np.std(a) * np.std(b))
    return {"correlation": float(np.mean((a - a.mean()) * (b - b.mean()))) / spread if spread > 0 else math.nan,
            "max_difference": float(np.abs(d).max()),
            "rms_difference_db": db(float(np.mean(d * d)))}


def print_run_notes(a: Path, b: Path) -> None:
    """What `run` recorded next to each WAV, when both files are there."""
    paths = a.with_suffix(".json"), b.with_suffix(".json")
    if not all(p.is_file() for p in paths):
        print("no run summary next to both files: the inputs could not be checked")
        return
    x, y = (json.loads(p.read_text(encoding="utf-8")) for p in paths)
    print(f"device: {x['device']} / {y['device']}; neural stage: {x['neural']} / {y['neural']}")
    print(f"seconds: {x['seconds']} / {y['seconds']}")
    print(f"inputs: {'identical' if x['input_sha256'] == y['input_sha256'] else 'DIFFERENT, the comparison means nothing'}")


def compare(args) -> int:
    a, b = read_wav(args.a), read_wav(args.b)
    if len(a) != len(b):
        print(f"lengths differ: {len(a)} and {len(b)} samples; comparing the first {min(len(a), len(b))}")
    length = min(len(a), len(b))
    if length == 0:
        raise InputProblem("one of the files is empty")
    print_run_notes(args.a, args.b)
    diff = difference(a[:length], b[:length])
    print(f"correlation: {diff['correlation']:.6f}")
    print(f"max difference: {diff['max_difference']:.6f} of full scale ({diff['max_difference'] * 32768:.0f} LSB)")
    print(f"RMS difference: {diff['rms_difference_db']:.2f} dBFS")
    ma, mb = score(a, args.scene), score(b, args.scene)
    print(f"{'':62}{'A':>10}{'B':>10}")
    for key, title in METRICS:
        print(f"{title:62}{number(ma[key]):>10}{number(mb[key]):>10}")
    return 0


# ---------------------------------------------------------------- command line


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(prog="echo_compare", description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = top.add_subparsers(dest="command", required=True)
    p = sub.add_parser("build", help="make the synthetic call from the two recordings")
    p.add_argument("--out", type=Path, required=True, help="folder for mic.m4a, system.m4a, clean.wav, labels.json")
    p.add_argument("--cache", type=Path, required=True, help="folder holding the MP3 recordings")
    p.add_argument("--download", action="store_true", help="fetch recordings missing from the cache (checked by SHA-256)")
    p.add_argument("--seconds", type=float, default=SCENE.seconds, help="length of the call (default: %(default)s)")
    p.set_defaults(handler=build)
    p = sub.add_parser("run", help="run the engine's echo removal; the device is the engine's choice")
    p.add_argument("scene", type=Path, help="folder made by build")
    p.add_argument("--out", type=Path, required=True, help="output WAV; a .json with the same name records the run")
    p.set_defaults(handler=run)
    p = sub.add_parser("metrics", help="residual echo, near-end speech loss, SI-SDR of one output")
    p.add_argument("wav", type=Path, help="output WAV of run")
    p.add_argument("--scene", type=Path, required=True, help="folder made by build")
    p.set_defaults(handler=metrics)
    p = sub.add_parser("compare", help="compare two outputs sample by sample and metric by metric")
    p.add_argument("a", type=Path, help="first output WAV")
    p.add_argument("b", type=Path, help="second output WAV")
    p.add_argument("--scene", type=Path, required=True, help="folder made by build")
    p.set_defaults(handler=compare)
    return top


def main() -> int:
    args = parser().parse_args()
    try:
        return args.handler(args)
    except InputProblem as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    except (StepFailed, audio.FfmpegError, audio.FfmpegMissing, OSError, wave.Error) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
