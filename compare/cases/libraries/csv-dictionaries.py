import csv
import sys

scale = int(sys.argv[1])
lines = ["name,value,kind\n"] + [f"row-{value},{value % 101},k{value % 5}\n" for value in range(700 * scale)]
reader = csv.DictReader(lines)
totals = {}
for row in reader:
    totals[row["kind"]] = totals.get(row["kind"], 0) + int(row["value"])

class Sink:
    def __init__(self):
        self.parts = []
    def write(self, value):
        self.parts.append(value)
        return len(value)

sink = Sink()
writer = csv.DictWriter(sink, fieldnames=["kind", "total"], lineterminator="\n")
writer.writeheader()
for kind, total in sorted(totals.items(), key=lambda item: item[0]):
    writer.writerow({"kind": kind, "total": total})
result = "".join(sink.parts)
print(len(totals), sum(totals.values()), len(result))
print(result)
