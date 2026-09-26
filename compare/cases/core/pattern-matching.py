import sys

scale = int(sys.argv[1])

def classify(value):
    match value:
        case None:
            return "none"
        case True | False:
            return "bool"
        case 0 | 1:
            return "small"
        case number if number < 0:
            return "negative"
        case other:
            return "other:" + str(other % 5)

counts = {}
values = [None, True, False, 0, 1, -3, 8, 14]
for unused in range(1000 * scale):
    for value in values:
        label = classify(value)
        counts[label] = counts.get(label, 0) + 1
print(sorted(counts.items(), key=lambda item: item[0]))
