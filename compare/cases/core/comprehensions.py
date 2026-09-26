import sys

scale = int(sys.argv[1])
limit = 1200 * scale
squares = [value * value for value in range(limit) if value % 3 == 1]
mapping = {value: value % 17 for value in squares if value % 5}
remainders = {value % 97 for value in squares}
pairs = [(left, right) for left in range(30) for right in range(20) if (left + right) % 7 == 0]
generated = sum(value * 2 for value in range(limit) if value % 11 == 0)
print(len(squares), len(mapping), len(remainders), len(pairs), generated)
print(sum(squares), sum(mapping.values()))
