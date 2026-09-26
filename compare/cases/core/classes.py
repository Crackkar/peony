import sys

scale = int(sys.argv[1])

class Root:
    factor = 2
    def __init__(self, value):
        self.value = value
    def score(self):
        return self.value * self.factor

class Left(Root):
    def score(self):
        return super().score() + 3

class Right(Root):
    factor = 5

class Combined(Left, Right):
    @property
    def doubled(self):
        return self.score() * 2
    @classmethod
    def from_pair(cls, left, right):
        return cls(left + right)
    @staticmethod
    def label():
        return "combined"

total = 0
for value in range(2000 * scale):
    total += Combined(value % 19).doubled
item = Combined.from_pair(4, 7)
print(total, item.score(), item.doubled, item.label())
print(isinstance(item, Root), isinstance(item, Left), issubclass(Combined, Right), item.factor)
