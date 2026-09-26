from pathlib import Path
import sys

scale = int(sys.argv[1])
root = Path("corpus-data")
root.mkdir(parents=True, exist_ok=True)
total = 0
for value in range(80 * scale):
    path = root / ("item-" + str(value) + ".txt")
    path.write_text(("line " + str(value) + " café\n") * 20)
    total += len(path.read_text())
entries = sorted(root.iterdir(), key=str)
binary = root / "payload.bin"
binary.write_bytes(bytes(range(128)))
print(len(entries), total, entries[0].name, entries[-1].suffix, entries[-1].parent.name)
print(binary.is_file(), root.is_dir(), len(binary.read_bytes()), binary.stem)
