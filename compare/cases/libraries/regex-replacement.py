import re
import sys

scale = int(sys.argv[1])
text = " ".join([f"item-{value}:{value % 19}" for value in range(600 * scale)])
pattern = re.compile(r"(?P<name>[a-z]+)-(\d+):(\d+)")

def replace(match):
    return match.group("name").upper() + "[" + match.group(3) + "]"

replaced, count = pattern.subn(replace, text)
templated = pattern.sub(r"\g<name>=\3", text, count=5)
print(count, len(replaced), replaced[:50], replaced[-50:])
print(templated[:100], len(pattern.findall(text)))
