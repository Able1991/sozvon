"""Установка моделей и меток движка: python install.py <папка данных>. Вызывается из setup.sh."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if __name__ == "__main__":
    from sozvon_engine import install, runtime
    runtime.prepare(offline=False)
    sys.exit(install.main())
