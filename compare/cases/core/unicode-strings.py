import sys

scale = int(sys.argv[1])
unit = "  Straße İstanbul Σίσυφος 中文 ١٢٣\n"
text = unit * (300 * scale)
words = text.split()
joined = "|".join(words[:40])
transformed = text.strip().upper().lower()
print(len(text), len(words), len(joined), len(transformed))
print("123".isdigit(), "١٢٣".isdecimal(), "Αλφα".isalpha(), "a2".isalnum())
print(text.count("中文"), text.find("İstanbul"), text.rfind("Σίσυφος"))
