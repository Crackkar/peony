from collections import Counter
import re
import sys

scale = int(sys.argv[1])
lines = []
levels = ["INFO", "WARN", "ERROR", "DEBUG"]
for value in range(2000 * scale):
    lines.append(f"2026-09-{value % 28 + 1:02d} {levels[value % 4]} user={value % 113} latency={value % 701}ms")
text = "\n".join(lines)
pattern = re.compile(r"^(?P<date>\d{4}-\d{2}-\d{2}) (?P<level>[A-Z]+) user=(?P<user>\d+) latency=(?P<latency>\d+)ms$", re.M)
counts = Counter()
latency = 0
maximum = 0
for match in pattern.finditer(text):
    counts[match.group("level")] += 1
    current = int(match.group("latency"))
    latency += current
    maximum = max(maximum, current)
print(len(lines), len(text), counts.most_common(), latency, maximum)
