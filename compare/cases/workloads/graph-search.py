from collections import defaultdict
import sys

scale = int(sys.argv[1])
nodes = 1200 * scale
graph = defaultdict(list)
for node in range(nodes):
    for offset in (1, 3, 11):
        target = (node + offset) % nodes
        graph[node].append(target)
        graph[target].append(node)
queue = [0]
distance = {0: 0}
cursor = 0
while cursor < len(queue):
    node = queue[cursor]
    cursor += 1
    for neighbor in graph[node]:
        if neighbor not in distance:
            distance[neighbor] = distance[node] + 1
            queue.append(neighbor)
print(len(graph), len(distance), max(distance.values()), sum(distance.values()), len(queue))
