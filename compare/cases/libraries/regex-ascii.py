import re
import sys

scale = int(sys.argv[1])
text = ("alpha_1 beta22 # comment_3\nitem99 value_7 end\n" * (30 * scale))
pattern = re.compile(r"\b(?P<name>[A-Za-z_]\w*)\b")
matches = list(pattern.finditer(text))
first = matches[0]
last = matches[-1]
print(len(matches), first.group("name"), first.span(), last.group(), last.span())
print(len(re.findall(r"\d+", text)), re.search(r"^item", text, re.M).group(), re.fullmatch(r"[a-z]+", "alphabet").group())
