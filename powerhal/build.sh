#!/bin/sh
# Builds dist/taoyao-powerhint612-v1.2.zip: transformer, validator, goldens,
# ship gates, shell and unit tests, deterministic zip. Arguments are passed to
# tools/build_module.py (--update-golden, --skip-tests, --input, ...).
cd "$(dirname "$0")" || exit 1
exec python3 -I tools/build_module.py "$@"
