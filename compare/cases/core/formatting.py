import sys

scale = int(sys.argv[1])
rows = []
for value in range(1, 400 * scale + 1):
    rows.append(f"{value:06d}|{value * 17:#010x}|{value / 7:>12.4f}")
template = "{0:>8} {name:^10} {1:+08d}"
sample = template.format("left", -42, name="center")
percent = "%08d %.3f %r" % (37, 2.5, "text")
print(len(rows), len("\n".join(rows)), rows[0], rows[-1])
print(sample)
print(percent)
