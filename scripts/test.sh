#!/bin/bash
# Runs the Swift tests. With only the Command Line Tools installed (no Xcode),
# Swift Testing's framework isn't on the default search paths, so add it.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=/Library/Developer/CommandLineTools/Library/Developer
if [[ -d "$DEV/Frameworks/Testing.framework" ]]; then
    swift test \
        -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
        -Xlinker -F -Xlinker "$DEV/Frameworks" \
        -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
        -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
else
    swift test "$@"
fi
