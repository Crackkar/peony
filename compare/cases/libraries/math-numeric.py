import math
import sys

scale = int(sys.argv[1])
integer_total = 0
floating_total = 0.0
for value in range(1, 2000 * scale + 1):
    integer_total += math.gcd(value * 18, value * 30, 84)
    floating_total += math.sin(value / 19.0) ** 2 + math.cos(value / 19.0) ** 2
print(integer_total, format(floating_total, ".8f"))
print(math.factorial(30), math.lcm(12, 18, 30), math.floor(-2.7), math.ceil(-2.7), math.trunc(-2.7))
print(math.isfinite(math.pi), math.isinf(math.inf), math.isnan(math.nan), format(math.log(1024, 2), ".6f"))
