from collections import Counter
import json
import sys

scale = int(sys.argv[1])
source = json.dumps([
    {"id": value, "kind": "kind-" + str(value % 9), "values": [value % 11, value % 17, value % 23]}
    for value in range(1200 * scale)
], separators=(",", ":"))
records = json.loads(source)
counts = Counter(record["kind"] for record in records)
totals = {record["id"]: sum(record["values"]) for record in records if record["id"] % 7 == 0}
result = json.dumps({"counts": dict(counts), "total": sum(totals.values()), "selected": len(totals)}, sort_keys=True, separators=(",", ":"))
print(len(source), len(records), result)
