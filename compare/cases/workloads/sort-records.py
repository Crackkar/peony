import sys

scale = int(sys.argv[1])
records = []
for value in range(1200 * scale):
    records.append({
        "id": value,
        "group": value % 41,
        "score": (value * 7919) % 100003,
        "name": "item-" + str(value % 997),
    })
records.sort(key=lambda item: item["id"])
records.sort(key=lambda item: item["name"])
records.sort(key=lambda item: item["score"], reverse=True)
records.sort(key=lambda item: item["group"])
selected = [item for item in records if item["score"] % 13 == 0]
checksum = sum((index + 1) * item["id"] for index, item in enumerate(selected))
print(len(records), len(selected), checksum)
print([(item["id"], item["group"], item["score"]) for item in records[:5]])
print([(item["id"], item["group"], item["score"]) for item in records[-5:]])
