import sys
import training
from training.metrics import summarize
from training import constants as renamed

scale = int(sys.argv[1])
values = [value % 23 for value in range(3000 * scale)]
result = summarize(values)
print(training.label(), result, renamed.MULTIPLIER)
print(training is __import__("training"), "training" in sys.modules, "training.metrics" in sys.modules)
