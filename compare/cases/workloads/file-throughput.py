import sys

scale = int(sys.argv[1])
block = "abcdefghij café 雪\n" * 100
with open("throughput.txt", "w", newline="") as output:
    for unused in range(40 * scale):
        output.write(block)
total = 0
lines = 0
for unused in range(20):
    with open("throughput.txt", newline="") as source:
        data = source.read()
        total += len(data)
        lines += data.count("\n")
with open("throughput.txt", "rb") as source:
    binary = source.read()
print(len(block), len(binary), total, lines, binary[:12], binary[-12:])
