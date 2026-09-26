import statistics
import sys

scale = int(sys.argv[1])
values = [((value * 37) % 1009) - 500 for value in range(5000 * scale + 1)]
weighted = [value % 7 + 1 for value in range(len(values))]
print(statistics.mean(values), format(statistics.fmean(values), ".10f"))
print(format(statistics.fmean(values, weighted), ".10f"), statistics.median(values), statistics.mode([3, 1, 2, 1, 2]))
try:
    statistics.mean([])
except statistics.StatisticsError as error:
    print(isinstance(error, ValueError))
