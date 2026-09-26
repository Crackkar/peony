from collections import Counter
import sys

scale = int(sys.argv[1])
words = ["red", "blue", "green", "red", "gold", "blue", "red"] * (1200 * scale)
left = Counter(words)
right = Counter({"red": 100 * scale, "blue": 200 * scale, "black": 50 * scale})
left.subtract(["green"] * (1500 * scale))
combined = left + right
intersection = left & right
union = left | right
print(left.most_common(), left.total(), list(left.elements())[:5])
print(combined.most_common(), list(intersection.items()), list(union.items()))
print(+left, -left, left["missing"])
