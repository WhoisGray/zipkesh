#!/usr/bin/env python3
"""Create a reproducible source release and its checksum (no third-party libs)."""
import hashlib
from pathlib import Path
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = (ROOT / "VERSION").read_text().strip()
EXCLUDED = {".git", "__pycache__", "work", "dist", ".DS_Store", ".pytest_cache"}


def package(destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / f"zipkesh-{VERSION}.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        for path in sorted(ROOT.rglob("*")):
            relative = path.relative_to(ROOT)
            if not path.is_file() or EXCLUDED.intersection(relative.parts) or path.suffix == ".pyc":
                continue
            entry = zipfile.ZipInfo(f"zipkesh/{relative.as_posix()}", date_time=(2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if path.suffix == ".sh" else 0o644
            entry.external_attr = (stat.S_IFREG | mode) << 16
            output.writestr(entry, path.read_bytes())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (destination / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
    return archive


if __name__ == "__main__":
    print(package(ROOT / "dist"))
