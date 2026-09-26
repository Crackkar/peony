import sys

scale = int(sys.argv[1])
total = 0
mixed = 0
for value in range(1, 4000 * scale + 1):
    total += (value * value + 7 * value - 3) // 5
    mixed ^= (value << (value % 7)) ^ (value >> (value % 5))
quotient, remainder = divmod(total, 97)
print(total, mixed, quotient, remainder)
print(bin(mixed), oct(remainder), hex(total % 65521))
