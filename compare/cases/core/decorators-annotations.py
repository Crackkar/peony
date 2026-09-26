import sys

scale = int(sys.argv[1])
calls = []

def traced(function):
    def wrapped(*args, **kwargs):
        calls.append("combine")
        return function(*args, **kwargs)
    return wrapped

@traced
def combine(left: int, right: int = 2) -> int:
    return left * 3 + right

total = 0
for value in range(1200 * scale):
    total += combine(value, right=value % 7)
label: str = "ready"
print(total, len(calls), calls[:3], label)
