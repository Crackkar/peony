import sys
import samplepkg
from samplepkg.metrics import summarize
from samplepkg import constants as renamed

scale = int(sys.argv[1])
values = [value % 23 for value in range(3000 * scale)]
result = summarize(values)
print(samplepkg.label(), result, renamed.MULTIPLIER)
print(samplepkg is __import__("samplepkg"), "samplepkg" in sys.modules, "samplepkg.metrics" in sys.modules)
