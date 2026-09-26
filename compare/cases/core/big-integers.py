import sys

scale = int(sys.argv[1])
power = 2 ** (700 * scale + 17)
factorial_mod = 1
modulus = 1000000007
for value in range(2, 600 * scale):
    factorial_mod = (factorial_mod * value) % modulus
roundtrip = (power * 99991) // 99991
print(len(str(power)), str(power)[-24:])
print(roundtrip == power, factorial_mod, pow(17, 250 * scale, modulus))
