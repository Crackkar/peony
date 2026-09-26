import csv
import statistics
import sys

scale = int(sys.argv[1])
lines = ["team,score,active\n"]
for value in range(1800 * scale):
    lines.append(f"team-{value % 13},{(value * 17) % 1000},{value % 4 == 0}\n")
groups = {}
for row in csv.DictReader(lines):
    groups.setdefault(row["team"], []).append(int(row["score"]))
report = []
for team, scores in sorted(groups.items(), key=lambda item: item[0]):
    report.append((team, len(scores), statistics.mean(scores), statistics.median(scores)))
print(len(report), sum(item[1] for item in report))
print(report)
