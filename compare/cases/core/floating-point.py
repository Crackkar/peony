import sys

scale = int(sys.argv[1])
total = 0.0
for value in range(1, 5000 * scale + 1):
    sign = -1.0 if value % 2 else 1.0
    total += sign / (value + 0.5)
values = [total, total * 1.25, total / 3.0, -0.0]
formatted = [format(value, ".12f") for value in values]
print(*formatted)
print(round(total, 8), min(values), max(values), sum(values))
