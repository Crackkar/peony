import os
import sys

scale = int(sys.argv[1])
os.makedirs("tree/left/deep", exist_ok=True)
os.makedirs("tree/right", exist_ok=True)
for value in range(60 * scale):
    with open(os.path.join("tree", "left", "file-" + str(value) + ".txt"), "w") as output:
        output.write("x" * (value + 1))
names = sorted(os.listdir("tree/left"))
os.rename("tree/left/file-0.txt", "tree/right/moved.txt")
with open("tree/right/replacement.txt", "w") as output:
    output.write("replacement")
os.replace("tree/right/replacement.txt", "tree/right/moved.txt")
with open("tree/right/moved.txt") as source:
    content = source.read()
print(bool(os.getcwd()), len(names), names[:3], names[-3:])
print(os.path.basename("tree/right/moved.txt"), os.path.dirname("tree/right/moved.txt"), content)
print(os.path.exists("tree/right/moved.txt"), os.path.isfile("tree/right/moved.txt"), os.path.isdir("tree/right"))
