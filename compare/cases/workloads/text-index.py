import sys

scale = int(sys.argv[1])
lines = []
for value in range(250 * scale):
    lines.append(f"section-{value % 37} alpha beta value-{value % 211} café 雪")
text = "\n".join(lines)
index = {}
checksum = 0
for line_number, line in enumerate(text.splitlines()):
    for word in line.lower().split():
        locations = index.setdefault(word, [])
        if len(locations) % 17 == 0:
            checksum += line_number
        locations.append(line_number)
print(len(text), len(lines), len(index), checksum)
print(len(index["alpha"]), len(index["café"]), index["section-0"][:5], index["value-17"][:5])
