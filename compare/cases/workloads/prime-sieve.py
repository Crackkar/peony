import math
import sys

scale = int(sys.argv[1])
limit = 12000 * scale
is_prime = [True] * (limit + 1)
is_prime[0] = False
is_prime[1] = False
candidate = 2
while candidate * candidate <= limit:
    if is_prime[candidate]:
        multiple = candidate * candidate
        while multiple <= limit:
            is_prime[multiple] = False
            multiple += candidate
    candidate += 1
primes = [value for value in range(limit + 1) if is_prime[value]]
print(limit, len(primes), primes[-10:])
print(sum(primes), math.gcd(*primes[:20]))
