import sys

scale = int(sys.argv[1])

def make_accumulator(start):
    value = start
    def add(amount=1):
        nonlocal value
        value += amount
        return value
    return add

def recursive_sum(value):
    if value <= 1:
        return value
    return value + recursive_sum(value - 1)

left = make_accumulator(10)
right = make_accumulator(-5)
checksum = 0
for value in range(1500 * scale):
    checksum += left(value % 7) - right(2)
print(checksum, left(), right(), recursive_sum(100))
