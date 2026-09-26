import copy
import sys

scale = int(sys.argv[1])

class Node:
    def __init__(self, name):
        self.name = name
        self.edges = []

root = Node("root")
child = Node("child")
root.edges.extend([child, child])
child.edges.append(root)
copies = []
for unused in range(200 * scale):
    copies.append(copy.deepcopy(root))
valid = all(item is not root and item.edges[0] is item.edges[1] and item.edges[0].edges[0] is item for item in copies)
shallow = copy.copy(root)
print(len(copies), valid, shallow is not root, shallow.edges is root.edges)
print(copies[-1].name, copies[-1].edges[0].name)
