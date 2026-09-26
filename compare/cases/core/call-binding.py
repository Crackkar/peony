import sys

scale = int(sys.argv[1])

def bind(a, b=2, /, c=3, *items, d=4, **named):
    return a + b + c + sum(items) + d + sum(named.values())

total = 0
for value in range(2000 * scale):
    total += bind(value % 11, 5, 7, 1, 2, d=9, x=3, y=4)

errors = []
for callback in (
    lambda: bind(a=1),
    lambda: bind(1, c=2, unknown="bad"),
):
    try:
        callback()
    except TypeError as error:
        errors.append(isinstance(error, TypeError))
print(total, errors)
