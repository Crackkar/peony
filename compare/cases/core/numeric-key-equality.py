import sys

scale = int(sys.argv[1])
mapping = {True: "bool", 1: "int", 1.0: "float", False: "false", 0: "zero", 0.0: "float-zero"}
values = []
for unused in range(3000 * scale):
    values.extend([True == 1, 1 == 1.0, hash(True) == hash(1), hash(1) == hash(1.0)])
keys = {(value, float(value)) for value in range(1000 * scale)}
print(mapping, len(mapping), all(values), len(keys))
print(mapping[True], mapping[1], mapping[1.0], mapping[False])
