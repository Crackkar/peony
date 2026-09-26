from collections import Counter
import re
import sys

scale = int(sys.argv[1])
paragraph = "Red blue green red; gold blue red. Café snow 雪 green! "
text = paragraph * (2500 * scale)
words = [word.lower() for word in re.findall(r"\w+", text)]
counts = Counter(words)
ranked = counts.most_common()
print(len(text), len(words), len(counts), counts.total())
print(ranked)
