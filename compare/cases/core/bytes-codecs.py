import sys

scale = int(sys.argv[1])
text = ("café-雪-" * (800 * scale)).removesuffix("-")
encoded = text.encode("utf-8")
pieces = encoded.split(b"-")
forward = encoded[1:-1:3]
reverse = encoded[::-5]
roundtrip = encoded.decode("utf-8")
print(len(text), len(encoded), len(pieces), len(forward), len(reverse))
print(roundtrip == text, encoded.find(b"caf"), bytes([0, 1, 127, 255]))
