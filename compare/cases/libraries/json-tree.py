import json
import sys

scale = int(sys.argv[1])
payload = {
    "rows": [{"id": value, "group": value % 17, "active": value % 3 == 0} for value in range(700 * scale)],
    "meta": {"name": "café 雪", "count": 700 * scale, "missing": None},
    "large": 123456789012345678901234567890,
}
encoded = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
decoded = json.loads(encoded)
print(len(encoded), len(decoded["rows"]), sum(row["group"] for row in decoded["rows"]))
print(decoded["meta"], decoded["large"], json.dumps(decoded["rows"][:2], indent=2, sort_keys=True))
