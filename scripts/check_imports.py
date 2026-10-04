#!/usr/bin/env python3
"""List the symbols a v2s binary imports that the running macOS does not provide.

The release is built with the newest SDK, whose availability annotations decide
which imports are weak. When an annotation is wrong, the import is strong and
dyld kills the app at launch on an older macOS, before it draws anything. A
missing weak import is bound to NULL and only crashes if the code calls it.

Exits with status 1 when a strong import or a strongly linked library is missing.

Usage: scripts/check_imports.py path/to/v2s.app/Contents/MacOS/v2s
"""

import collections
import platform
import re
import subprocess  # nosec B404
import sys

# The Apple developer tools that read the binary and the system libraries it links.
TOOLS = {
    "dyld_info": "/usr/bin/dyld_info",
    "nm": "/usr/bin/nm",
    "otool": "/usr/bin/otool",
    "xcrun": "/usr/bin/xcrun",
}


def run(tool, *args):
    # Only the fixed tools above run, from an argument list and without a shell. Their
    # arguments are the binary under test and the system library paths it links.
    command = [TOOLS[tool], *args]
    return subprocess.run(command, capture_output=True, text=True, check=False).stdout  # nosec B603  # nosemgrep


def linked_libraries(binary, arch):
    """Maps each library name `nm` prints to its install path and whether it is weak-linked."""
    libraries = {}
    load_command = None
    for line in run("otool", "-arch", arch, "-l", binary).splitlines():
        line = line.strip()
        if line.startswith("cmd "):
            load_command = line.split()[1]
        elif line.startswith("name ") and load_command in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB"):
            path = line.split()[1]
            name = re.sub(r"(\.[AB])?\.dylib$", "", path.rsplit("/", 1)[-1])
            libraries[name] = (path, load_command == "LC_LOAD_WEAK_DYLIB")
    return libraries


def imported_symbols(binary, arch):
    """Maps each library name to the symbols imported from it and whether each is weak."""
    imports = collections.defaultdict(list)
    for line in run("nm", "-arch", arch, "-m", "-u", binary).splitlines():
        match = re.match(r"\s*\(undefined\) (weak )?external (\S+) \(from (\S+)\)", line)
        if match:
            weak, symbol, library = match.groups()
            imports[library].append((symbol, weak is not None))
    return imports


def exported_symbols(path, cache, seen=frozenset()):
    """Symbols a system library exports, including those of the libraries it re-exports."""
    if path not in cache:
        output = run("dyld_info", "-exports", path)
        symbols = set(re.findall(r"^\s+0x[0-9A-Fa-f]+\s+(\S+)", output, re.M))
        symbols |= set(re.findall(r"^\s+\[re-export\]\s+(\S+)", output, re.M))
        for reexported in re.findall(r"^\s+re-export\s+(\S+)", run("dyld_info", "-linked_dylibs", path), re.M):
            if reexported not in seen:
                symbols |= exported_symbols(reexported, cache, seen | {path})
        cache[path] = symbols
    return cache[path]


def demangle(symbol):
    return run("xcrun", "swift-demangle", "--compact", symbol).strip() or symbol


def main():
    binary = sys.argv[1]
    arch = platform.machine()
    libraries = linked_libraries(binary, arch)
    cache = {}
    missing_strong = 0
    missing_weak = 0

    for library, symbols in sorted(imported_symbols(binary, arch).items()):
        path, library_is_weak = libraries[library]
        if path.startswith("@rpath/"):
            # Embedded frameworks such as Sparkle ship inside the app bundle.
            continue

        exported = exported_symbols(path, cache)
        if not exported:
            if library_is_weak:
                print(f"weak   {path} is not on this macOS")
            else:
                missing_strong += 1
                print(f"STRONG {path} is not on this macOS")
            continue

        for symbol, symbol_is_weak in symbols:
            if symbol in exported:
                continue
            if symbol_is_weak or library_is_weak:
                missing_weak += 1
                print(f"weak   {library}: {demangle(symbol)}")
            else:
                missing_strong += 1
                print(f"STRONG {library}: {demangle(symbol)}")

    print(
        f"Imports this macOS does not provide: {missing_strong} strong (launch fails), "
        f"{missing_weak} weak (bound to NULL)"
    )
    return 1 if missing_strong else 0


if __name__ == "__main__":
    sys.exit(main())
