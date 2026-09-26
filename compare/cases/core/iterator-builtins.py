import sys

scale = int(sys.argv[1])
values = list(range(2500 * scale))
mapped = map(lambda value: value * 3, values)
filtered = filter(lambda value: value % 7 == 0, mapped)
selected = list(filtered)
zipped = list(zip(range(len(selected)), reversed(selected)))
enumerated = list(enumerate(selected[:50], 10))
print(len(selected), sum(selected), len(zipped), enumerated[-1])
print(all(value % 21 == 0 for value in selected), any(value > 10000 for value in selected))
