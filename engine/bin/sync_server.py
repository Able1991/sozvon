"""Sync with your own server: send new and changed calls, download the ones missing here, sync notes,
delete on the server only the calls deleted in Sozvon, move calls deleted on another Mac to the Trash.

  python bin/sync_server.py
Progress lines "STATUS: ...", last line "RESULT: ok <sent> <deleted> <downloaded> <trashed> <failed>" or
"RESULT: error <code> <message>" (docs/CONTRACT.md). Exit codes: 0 ok, 1 some calls failed
(the RESULT line still says ok) or another error, 2 not configured or bad address or password.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

if __name__ == "__main__":
    from sozvon_engine import remote
    sys.exit(remote.main())
