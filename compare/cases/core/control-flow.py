import sys

scale = int(sys.argv[1])
hits = []
total = 0
for value in range(8000 * scale):
    if value % 15 == 0:
        hits.append("fizzbuzz")
    elif value % 3 == 0:
        hits.append("fizz")
    elif value % 5 == 0:
        hits.append("buzz")
    else:
        total += value
else:
    total += len(hits)

cursor = 0
while cursor < len(hits):
    if cursor == 200 * scale:
        break
    cursor += 1
else:
    cursor = -1
print(total, len(hits), cursor)
print((0 and 1) or ("left" if total > 0 else "right"))
