#!/usr/bin/env python3
"""List the symbols a v2s binary imports that the running macOS does not provide.

The release is built with the newest SDK, whose availability annotations decide
which imports are weak. When an annotation is wrong, the import is strong and
dyld kills the app at launch on an older macOS, before it draws anything. A
missing weak import is bound to NULL and only crashes if the code calls it.

Exits with status 1 when a strong import or a strongly linked library is missing,
or when the binary cannot be inspected for the running architecture.

Usage: scripts/check_imports.py path/to/v2s.app/Contents/MacOS/v2s
"""

import collections
import ctypes
import os
import platform
import re
import subprocess  # nosec B404
import sys

# The Apple developer tools that read the binary and the system libraries it links.
TOOLS = {
    "dyld_info": "/usr/bin/dyld_info",
    "lipo": "/usr/bin/lipo",
    "nm": "/usr/bin/nm",
    "otool": "/usr/bin/otool",
    "xcrun": "/usr/bin/xcrun",
}


def run(tool, *args):
    # Only the fixed tools above run, from an argument list and without a shell. Their
    # arguments are the binary under test and the system library paths it links.
    command = [TOOLS[tool], *args]
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout  # nosec B603  # nosemgrep


_shared_cache_contains_path = ctypes.CDLL("/usr/lib/libSystem.B.dylib")._dyld_shared_cache_contains_path
_shared_cache_contains_path.argtypes = [ctypes.c_char_p]
_shared_cache_contains_path.restype = ctypes.c_bool


def library_exists(path):
    """Whether this macOS has the library, either in the dyld shared cache or on disk.

    Most system libraries exist only in the shared cache, so a file check alone is not
    enough. dyld_info's error for a missing path differs between Xcode versions ("file
    not found", "non-mach-o in fat file"), so dyld itself is asked instead.
    """
    return _shared_cache_contains_path(os.fsencode(path)) or os.path.exists(path)


LINK_COMMANDS = ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_LOAD_UPWARD_DYLIB", "LC_REEXPORT_DYLIB")


def short_name(path):
    """The name `nm -m` prints for a library: its file name up to the first dot.

    That drops the version and extension, so /usr/lib/libc++.1.dylib is "libc++" and
    /usr/lib/libSystem.B.dylib is "libSystem". A framework binary has no dot.
    """
    return path.rsplit("/", 1)[-1].split(".", 1)[0]


def linked_libraries(binary, arch):
    """The install path of every library the binary links, and whether it is weak-linked."""
    libraries = []
    load_command = None
    for line in run("otool", "-arch", arch, "-l", binary).splitlines():
        line = line.strip()
        if line.startswith("cmd "):
            load_command = line.split()[1]
        elif line.startswith("name ") and load_command in LINK_COMMANDS:
            libraries.append((line.split()[1], load_command == "LC_LOAD_WEAK_DYLIB"))
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


# Slices a process of each architecture can load, best first. Apple's own arm64
# libraries are often built for arm64e only.
LOADABLE_SLICES = {"arm64": ("arm64", "arm64e")}


def arch_options(path, arch):
    """The dyld_info options that limit it to the slice of `path` an `arch` process loads.

    A library only in the dyld shared cache has no file, and the cache is built for the
    running architecture, so it needs none. A file on disk may be universal, and
    without -arch dyld_info would print the exports of every slice.
    """
    if not os.path.exists(path):
        return []
    slices = run("lipo", "-archs", path).split()
    for candidate in LOADABLE_SLICES.get(arch, (arch,)):
        if candidate in slices:
            return ["-arch", candidate]
    raise ValueError(f"{path} has no slice an {arch} process can load (available: {', '.join(slices) or 'none'})")


def exported_symbols(path, arch, cache, seen=frozenset()):
    """Symbols a system library exports, including those of the libraries it re-exports.

    Returns the symbols and the (library, re-exported path) pairs whose re-exported
    library this macOS does not have; dyld cannot load the library without them.
    Returns None when this macOS does not have the library itself, which is expected
    for a weak-linked library on an older macOS. A library that exists must be readable.
    """
    if path not in cache:
        if not library_exists(path):
            cache[path] = None
            return None
        options = arch_options(path, arch)
        output = run("dyld_info", *options, "-exports", path)
        symbols = set(re.findall(r"^\s+0x[0-9A-Fa-f]+\s+(\S+)", output, re.M))
        symbols |= set(re.findall(r"^\s+\[re-export\]\s+(\S+)", output, re.M))
        missing = set()
        linked = run("dyld_info", *options, "-linked_dylibs", path)
        for reexported in re.findall(r"^\s+re-export\s+(\S+)", linked, re.M):
            if reexported in seen:
                continue
            nested = exported_symbols(reexported, arch, cache, seen | {path})
            if nested is None:
                missing.add((path, reexported))
            else:
                symbols |= nested[0]
                missing |= nested[1]
        cache[path] = (symbols, missing)
    return cache[path]


def demangle(symbol):
    return run("xcrun", "swift-demangle", "--compact", symbol).strip() or symbol


def main():
    if len(sys.argv) != 2:
        raise ValueError("usage: scripts/check_imports.py path/to/v2s.app/Contents/MacOS/v2s")
    binary = sys.argv[1]
    arch = platform.machine()
    architectures = run("lipo", "-archs", binary).split()
    if arch not in architectures:
        raise ValueError(f"{binary} has no {arch} slice (available: {', '.join(architectures) or 'none'})")
    linked = linked_libraries(binary, arch)
    imports = imported_symbols(binary, arch)
    # v2s always has linked libraries and imports. Empty results mean the tools
    # could not read the app, or their output no longer matches our parsers.
    if not linked or not imports:
        raise ValueError(f"Could not read linked libraries and imported symbols from {binary} ({arch})")
    # nm names a library only by its short name, so imports are matched that way.
    libraries = collections.defaultdict(set)
    for path, is_weak in linked:
        libraries[short_name(path)].add((path, is_weak))
    cache = {}
    missing_strong = 0
    missing_weak = 0

    # dyld loads every linked library, including one the binary imports nothing from
    # (kept with -needed_library, for example), and the libraries each re-exports,
    # so all of them must exist. Two load commands can share a short name, so this
    # goes through the load commands rather than the names.
    for path, library_is_weak in sorted(set(linked)):
        # Embedded frameworks such as Sparkle ship inside the app bundle.
        if path.startswith("@rpath/"):
            continue
        result = exported_symbols(path, arch, cache)
        if result is None:
            if library_is_weak:
                print(f"weak   {path} is not on this macOS")
            else:
                missing_strong += 1
                print(f"STRONG {path} is not on this macOS")
            continue
        # Weak linking only lets the library itself be absent. Once dyld loads it,
        # the libraries it re-exports are required whatever the binary's link says.
        for parent, child in sorted(result[1]):
            missing_strong += 1
            print(f"STRONG {parent} re-exports {child}, which is not on this macOS")

    for library, symbols in sorted(imports.items()):
        candidates = libraries.get(library, set())
        if not candidates:
            raise ValueError(f"{binary} imports symbols from {library}, which none of its load commands names")
        paths = sorted({path for path, _ in candidates})
        if len(paths) > 1:
            # nm does not say which of them each symbol binds to.
            raise ValueError(
                f"{binary} imports symbols from {library}, a name several linked libraries share: {', '.join(paths)}"
            )
        path = paths[0]
        # Weak only if every load command of the library is weak.
        library_is_weak = all(is_weak for _, is_weak in candidates)
        if path.startswith("@rpath/"):
            continue

        result = exported_symbols(path, arch, cache)
        if result is None:
            # Already reported above.
            continue
        exported = result[0]

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
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or error.stdout.strip() or "no diagnostic output"
        print(f"error: {error.cmd[0]} exited with status {error.returncode}: {detail}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
