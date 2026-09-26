import sys

scale = int(sys.argv[1])

class Shape:
    def area(self):
        raise NotImplementedError()

class Rectangle(Shape):
    def __init__(self, width, height):
        self.width = width
        self.height = height
    def area(self):
        return self.width * self.height

class Triangle(Shape):
    def __init__(self, base, height):
        self.base = base
        self.height = height
    def area(self):
        return self.base * self.height / 2

shapes = []
for value in range(2500 * scale):
    if value % 2:
        shapes.append(Rectangle(value % 17 + 1, value % 23 + 1))
    else:
        shapes.append(Triangle(value % 19 + 1, value % 29 + 1))
areas = [shape.area() for shape in shapes]
print(len(shapes), format(sum(areas), ".3f"), format(min(areas), ".3f"), format(max(areas), ".3f"))
print(sum(isinstance(shape, Rectangle) for shape in shapes), sum(isinstance(shape, Triangle) for shape in shapes))
