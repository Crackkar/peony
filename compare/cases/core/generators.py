import sys

scale = int(sys.argv[1])

def running(limit):
    total = 0
    try:
        for value in range(limit):
            incoming = yield total
            total += value if incoming is None else incoming
    finally:
        closed.append(total)
    return total

closed = []
generator = running(500 * scale)
values = [next(generator)]
for value in range(500 * scale - 1):
    values.append(generator.send(3 if value % 10 == 0 else None))
generator.close()
print(len(values), sum(values), closed)
print(sum(value * value for value in range(1000 * scale)))
