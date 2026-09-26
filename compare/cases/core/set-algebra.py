import sys

scale = int(sys.argv[1])
left = {value % (1300 * scale + 7) for value in range(9000 * scale)}
right = {value % (1700 * scale + 11) for value in range(7000 * scale) if value % 3}
union = left | right
intersection = left & right
difference = left - right
symmetric = (left - right) | (right - left)
mutable = left.copy()
for value in range(0, 500 * scale, 2):
    mutable.discard(value)
mutable.update(range(2000 * scale, 2200 * scale))
print(len(left), len(right), len(union), len(intersection), len(difference), len(symmetric), len(mutable))
print(sum(union), sorted(intersection)[:5], sorted(difference)[-5:])
