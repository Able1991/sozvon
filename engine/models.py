"""Download a model: python models.py <data dir> <model>. Logic lives in sozvon_engine/install.py."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if __name__ == "__main__":
    import os
    os.environ["HF_HUB_OFFLINE"] = "0"
    from sozvon_engine import install, models
    if len(sys.argv) != 3:
        sys.exit("usage: python models.py <data dir> <model>")
    data, name = sys.argv[1], sys.argv[2]
    if name not in models.MODELS:
        sys.exit(f"unknown model {name!r}; available: {', '.join(models.MODELS)}")
    print(install.ensure_model(Path(data), name))
