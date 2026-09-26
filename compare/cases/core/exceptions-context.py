import sys

scale = int(sys.argv[1])
events = []

class Guard:
    def __init__(self, label, suppress=False):
        self.label = label
        self.suppress = suppress
    def __enter__(self):
        events.append("enter:" + self.label)
        return self
    def __exit__(self, kind, value, trace):
        events.append("exit:" + self.label + ":" + ("error" if kind is not None else "ok"))
        return self.suppress

for value in range(300 * scale):
    try:
        with Guard(str(value % 3), value % 13 == 0):
            if value % 13 == 0:
                raise ValueError(str(value))
            if value % 17 == 0:
                raise KeyError(str(value))
    except KeyError:
        events.append("key")
    else:
        events.append("done")
    finally:
        events.append("finally")
print(len(events), events.count("key"), events.count("done"), events[-4:])
