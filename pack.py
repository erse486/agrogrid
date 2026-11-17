"""Build the QField application plugin ZIP."""
import re
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parent
PLUGIN = ROOT / "plugin"
DIST = ROOT / "dist"
FILES = ("main.qml", "metadata.txt", "icon.svg", "Grid.js", "Geometry.js", "NativeCut.js")


def build():
    DIST.mkdir(exist_ok=True)
    metadata = (PLUGIN / "metadata.txt").read_text(encoding="utf-8")
    version = re.search(r"^version=(\d+\.\d+\.\d+)$", metadata, re.MULTILINE).group(1)
    target = DIST / f"agrogrid-v{version}.zip"
    with ZipFile(target, "w", ZIP_DEFLATED, compresslevel=9) as archive:
        for name in FILES:
            info = ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            archive.writestr(info, (PLUGIN / name).read_bytes(), compresslevel=9)
    with ZipFile(target) as archive:
        assert archive.namelist() == list(FILES)
        assert archive.testzip() is None
        assert all(archive.read(name) == (PLUGIN / name).read_bytes() for name in FILES)
    print(target.name, target.stat().st_size, "B")


if __name__ == "__main__":
    build()
