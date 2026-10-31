#!/usr/bin/env python3
"""Compatibility shim: the matrix report is now scripts/report.py.

This script used to build the report itself, from the latest single run per
cell, against a hardcoded profile list and a hardcoded `fixed-500qps` glob.
Its rendering moved to scripts/reportlib.py and is driven by scripts/report.py,
which medians across repeats and discovers what ran from results/.

Kept so existing commands and run-comprehensive-tests.sh keep working.
"""
import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

if __name__ == "__main__":
    print("note: generate-report.py now delegates to scripts/report.py "
          "(same report, medianed across repeats)", file=sys.stderr)
    sys.argv[0] = os.path.join(HERE, "scripts", "report.py")
    runpy.run_path(sys.argv[0], run_name="__main__")
