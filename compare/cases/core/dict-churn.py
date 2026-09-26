import sys

scale = int(sys.argv[1])
values = {}
limit = 5000 * scale
for key in range(limit):
    values[key] = key * 3
for key in range(0, limit, 4):
    del values[key]
for key in range(0, limit, 8):
    values[key] = -key
for key in range(limit, limit + 1000 * scale):
    values.setdefault(key, key + 1)
copy = values.copy()
removed = 0
for key in list(copy.keys())[::11]:
    removed += copy.pop(key)
print(len(values), sum(values.values()), list(values.items())[:4], list(values.items())[-4:])
print(len(copy), removed, len(list(values.keys())), len(list(values.items())))
