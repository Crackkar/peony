import json
import sys

scale = int(sys.argv[1])
values = [f"row-{value}-" + "abcdefghij" * 20 + "-é-雪" for value in range(500 * scale)]
encoded = json.dumps(values, ensure_ascii=False)
ascii_encoded = json.dumps(values[:10], ensure_ascii=True)
decoded = json.loads(encoded.encode("utf-8"))
print(len(values), len(encoded), len(ascii_encoded), decoded == values)
try:
    json.loads('{"broken": [1,}')
except json.JSONDecodeError as error:
    print(isinstance(error, ValueError), error.pos, error.lineno, error.colno)
