import re
import sys

scale = int(sys.argv[1])
text = ("Αλφα βήτα ١٢٣ 中文 café\n" * (450 * scale))
words = re.findall(r"\w+", text, re.I)
ascii_words = re.findall(r"\w+", text, re.A)
boundaries = re.findall(r"\bβήτα\b", text)
split = re.split(r"\s+", text.strip(), maxsplit=7)
print(len(words), len(ascii_words), len(boundaries), len(split))
print(words[:5], ascii_words[:5], split[-1][:12])
