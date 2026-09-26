from collections import defaultdict
import sys

scale = int(sys.argv[1])
groups = defaultdict(list)
for value in range(5000 * scale):
    groups[value % 31].append(value)
totals = defaultdict(int)
for key, values in groups.items():
    totals[key] += sum(values)
before = len(groups)
missing_get = groups.get("absent")
contains = "absent" in groups
created = groups["created"]
print(before, len(groups), missing_get, contains, created)
pairs = [(key, len(value)) for key, value in groups.items() if isinstance(key, int)]
pairs.sort(key=lambda item: item[0])
print(len(totals), sum(totals.values()), pairs[:4])
