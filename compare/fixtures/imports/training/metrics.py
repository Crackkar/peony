from .constants import MULTIPLIER

def summarize(values):
    return len(values), sum(values), sum(value * MULTIPLIER for value in values)
