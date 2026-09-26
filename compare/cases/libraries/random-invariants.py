import random
import sys

scale = int(sys.argv[1])
random.seed("corpus-seed")
population = list(range(5000 * scale))
sample = random.sample(population, 1000 * scale)
choices = random.choices(["a", "b", "c"], weights=[1, 3, 6], k=2000 * scale)
shuffled = list(range(2000 * scale))
random.shuffle(shuffled)
uniforms = [random.uniform(-2.0, 7.0) for unused in range(1000 * scale)]
print(len(sample), len(set(sample)), min(sample) >= 0, max(sample) < len(population))
print(len(choices), all(value in {"a", "b", "c"} for value in choices), sorted(shuffled) == list(range(2000 * scale)))
print(all(-2.0 <= value <= 7.0 for value in uniforms), 0 <= random.randrange(10, 100, 3) < 100)
