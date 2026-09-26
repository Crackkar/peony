import sys

scale = int(sys.argv[1])
values = [(value * 7919) % 104729 for value in range(5000 * scale)]
values.sort(reverse=True)
values.sort(key=lambda value: value % 17)
middle = values[10:-10:3]
reverse = values[::-7]
copy = values.copy()
copy.reverse()
copy.extend(middle[:100])
for value in range(100):
    copy.insert(value * 2, value)
for unused in range(50):
    copy.pop()
print(len(values), sum(values), values[:5], values[-5:])
print(len(middle), len(reverse), len(copy), copy.count(7))
