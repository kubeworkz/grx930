import inspect
import openlane.flow as F
import openlane.flows as Fl
import re

src = inspect.getsource(F)

# 1) How duplicate step ids are suffixed
for m in re.finditer(r"(?m)^.*(occurrence|duplicate|f\".*-\{.*\}\"|-3|suffix).*$", src):
    line = m.group(0)
    if "step" in line.lower() or "id" in line.lower():
        print("LINE:", line.strip())

print("=" * 40)

# 2) The -F / resume resolution logic: search for "from" handling in run()
idx = src.find("def run")
print(src[idx: idx + 4000])
