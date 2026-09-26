import csv
import sys

scale = int(sys.argv[1])
lines = ["name,value,note\n"]
for value in range(1000 * scale):
    lines.append(f'item-{value},{value % 97},"part {value}, doubled ""quote"""\n')
reader = csv.reader(lines)
header = next(reader)
total = 0
notes = 0
for row in reader:
    total += int(row[1])
    notes += len(row[2])
print(header, reader.line_num, total, notes)
print(list(csv.reader(['1,2.5,"three"\n'], quoting=csv.QUOTE_NONNUMERIC)))
