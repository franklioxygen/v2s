"""Exercise the symbol checker against real Mach-O files and Apple tools."""

import pathlib
import platform
import subprocess  # nosec B404
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "scripts" / "check_imports.py"


@unittest.skipUnless(sys.platform == "darwin", "Requires Apple's Mach-O tools")
class CheckImportsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        """Build fixtures without executing or loading any of them."""
        temporary = tempfile.TemporaryDirectory(prefix="v2s-check-imports-")
        cls.addClassCleanup(temporary.cleanup)
        cls.root = pathlib.Path(temporary.name)
        cls.arch = platform.machine()
        other_arch = "x86_64" if cls.arch == "arm64" else "arm64"

        source = cls.root / "main.c"
        source.write_text('#include <stdio.h>\nint main(void) { return puts("fixture") < 0; }\n')
        cls.native = cls.root / "native"
        cls.other_arch = cls.root / "other-arch"
        cls.compile("-arch", cls.arch, source, "-o", cls.native)
        cls.compile("-arch", other_arch, source, "-o", cls.other_arch)

        # A valid header still lets lipo identify the architecture, but the load
        # commands and symbol table are missing, so inspection must fail.
        cls.truncated = cls.root / "truncated"
        cls.truncated.write_bytes(cls.native.read_bytes()[:32])

        library_source = cls.root / "library.c"
        library_source.write_text("int import_check_fixture(void) { return 0; }\n")
        library = cls.root / "libimport_check_fixture.dylib"
        cls.missing_library = cls.root / "missing" / library.name
        cls.compile(
            "-arch", cls.arch, "-dynamiclib", library_source,
            "-install_name", cls.missing_library, "-o", library,
        )

        source.write_text(
            "extern int import_check_fixture(void);\n"
            "int main(void) { return import_check_fixture(); }\n"
        )
        cls.strong = cls.root / "strong"
        cls.compile("-arch", cls.arch, source, library, "-o", cls.strong)

        source.write_text(
            "extern int import_check_fixture(void) __attribute__((weak_import));\n"
            "int main(void) { return import_check_fixture ? import_check_fixture() : 0; }\n"
        )
        cls.weak = cls.root / "weak"
        cls.compile("-arch", cls.arch, source, f"-Wl,-weak_library,{library}", "-o", cls.weak)

        # An umbrella library that exists but re-exports a library that does not. The
        # linker needs the re-exported library at its install path, so it is removed
        # only after everything that links it is built.
        cls.reexported = cls.root / "libreexported_fixture.dylib"
        library_source.write_text("int reexported_fixture(void) { return 0; }\n")
        cls.compile(
            "-arch", cls.arch, "-dynamiclib", library_source,
            "-install_name", cls.reexported, "-o", cls.reexported,
        )
        umbrella_source = cls.root / "umbrella.c"
        umbrella_source.write_text("int umbrella_fixture(void) { return 0; }\n")
        cls.umbrella = cls.root / "libumbrella_fixture.dylib"
        cls.compile(
            "-arch", cls.arch, "-dynamiclib", umbrella_source,
            "-install_name", cls.umbrella, f"-Wl,-reexport_library,{cls.reexported}", "-o", cls.umbrella,
        )
        source.write_text(
            "extern int reexported_fixture(void);\n"
            "int main(void) { return reexported_fixture(); }\n"
        )
        cls.through_umbrella = cls.root / "through-umbrella"
        cls.compile("-arch", cls.arch, source, cls.umbrella, "-o", cls.through_umbrella)
        # Importing only the umbrella's own symbol still needs what it re-exports.
        source.write_text(
            "extern int umbrella_fixture(void);\n"
            "int main(void) { return umbrella_fixture(); }\n"
        )
        cls.umbrella_only = cls.root / "umbrella-only"
        cls.compile("-arch", cls.arch, source, cls.umbrella, "-o", cls.umbrella_only)
        source.write_text(
            "extern int umbrella_fixture(void) __attribute__((weak_import));\n"
            "int main(void) { return umbrella_fixture ? umbrella_fixture() : 0; }\n"
        )
        cls.weak_umbrella = cls.root / "weak-umbrella"
        cls.compile("-arch", cls.arch, source, f"-Wl,-weak_library,{cls.umbrella}", "-o", cls.weak_umbrella)
        cls.reexported.unlink()

        # Two linked libraries that nm would both call "libduplicate_fixture": the
        # first is missing and the second exists.
        duplicates = []
        for version, install_name in (("1", cls.root / "missing" / "libduplicate_fixture.1.dylib"),
                                      ("2", cls.root / "libduplicate_fixture.2.dylib")):
            library_source.write_text(f"int duplicate_fixture_{version}(void) {{ return 0; }}\n")
            duplicate = cls.root / f"libduplicate_fixture.{version}.dylib"
            cls.compile(
                "-arch", cls.arch, "-dynamiclib", library_source,
                "-install_name", install_name, "-o", duplicate,
            )
            duplicates.append(duplicate)
        cls.missing_duplicate = cls.root / "missing" / "libduplicate_fixture.1.dylib"
        source.write_text('#include <stdio.h>\nint main(void) { return puts("fixture") < 0; }\n')
        cls.duplicate_names = cls.root / "duplicate-names"
        cls.compile(
            "-arch", cls.arch, source, *(f"-Wl,-needed_library,{path}" for path in duplicates),
            "-o", cls.duplicate_names,
        )

        # Two present libraries sharing a short name, with a symbol imported from one:
        # nm's "(from libshared_fixture)" cannot tell which library supplies it.
        shared = []
        for version in ("1", "2"):
            library_source.write_text(f"int shared_fixture_{version}(void) {{ return 0; }}\n")
            library_path = cls.root / f"libshared_fixture.{version}.dylib"
            cls.compile(
                "-arch", cls.arch, "-dynamiclib", library_source,
                "-install_name", library_path, "-o", library_path,
            )
            shared.append(library_path)
        source.write_text(
            "extern int shared_fixture_2(void);\n"
            "int main(void) { return shared_fixture_2(); }\n"
        )
        cls.ambiguous = cls.root / "ambiguous"
        cls.compile("-arch", cls.arch, source, *(f"-Wl,-needed_library,{path}" for path in shared), "-o", cls.ambiguous)

        # Linked strongly but nothing imported from it, so only its load command needs it.
        source.write_text('#include <stdio.h>\nint main(void) { return puts("fixture") < 0; }\n')
        cls.unreferenced = cls.root / "unreferenced"
        cls.compile("-arch", cls.arch, source, f"-Wl,-needed_library,{library}", "-o", cls.unreferenced)

        # A universal library whose native slice lacks the imported symbol, which only
        # the other slice exports. The binary links a native-only build first.
        cls.universal = cls.root / "libslice_fixture.dylib"
        library_source.write_text("int slice_fixture(void) { return 0; }\n")
        cls.compile(
            "-arch", cls.arch, "-dynamiclib", library_source,
            "-install_name", cls.universal, "-o", cls.universal,
        )
        source.write_text(
            "extern int slice_fixture(void);\n"
            "int main(void) { return slice_fixture(); }\n"
        )
        cls.sliced = cls.root / "sliced"
        cls.compile("-arch", cls.arch, source, cls.universal, "-o", cls.sliced)
        other_slice = cls.root / "other-slice.dylib"
        cls.compile(
            "-arch", other_arch, "-dynamiclib", library_source,
            "-install_name", cls.universal, "-o", other_slice,
        )
        library_source.write_text("int other_fixture(void) { return 0; }\n")
        native_slice = cls.root / "native-slice.dylib"
        cls.compile(
            "-arch", cls.arch, "-dynamiclib", library_source,
            "-install_name", cls.universal, "-o", native_slice,
        )
        cls.lipo("-create", native_slice, other_slice, "-output", cls.universal)

        # libc++ is installed as libc++.1.dylib, which nm calls "libc++".
        cxx_source = cls.root / "main.cpp"
        cxx_source.write_text('#include <string>\nint main() { return std::string("x").size() != 1; }\n')
        cls.versioned = cls.root / "versioned"
        cls.compile("-arch", cls.arch, cxx_source, "-o", cls.versioned, compiler="clang++")

    @staticmethod
    def compile(*args, compiler="clang"):
        """Compile only the generated fixtures with Apple's fixed tool path."""
        command = ["/usr/bin/xcrun", compiler, *map(str, args)]
        subprocess.run(command, capture_output=True, text=True, check=True)  # nosec B603  # nosemgrep

    @staticmethod
    def lipo(*args):
        """Combine generated fixture slices with Apple's fixed tool path."""
        command = ["/usr/bin/lipo", *map(str, args)]
        subprocess.run(command, capture_output=True, text=True, check=True)  # nosec B603  # nosemgrep

    def check(self, binary):
        """Run the real CLI against a fixture and capture its exit status."""
        command = [sys.executable, str(SCRIPT), str(binary)]
        return subprocess.run(command, capture_output=True, text=True, check=False)  # nosec B603  # nosemgrep

    def assert_inspection_fails(self, binary):
        result = self.check(binary)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("error:", result.stderr)
        self.assertNotIn("Imports this macOS does not provide:", result.stdout)
        return result

    def test_missing_binary_fails(self):
        result = self.assert_inspection_fails(self.root / "not-found")
        self.assertIn("not-found", result.stderr)

    def test_non_mach_o_file_fails(self):
        self.assert_inspection_fails(SCRIPT)

    def test_missing_native_architecture_fails(self):
        result = self.assert_inspection_fails(self.other_arch)
        self.assertIn(f"no {self.arch} slice", result.stderr)

    def test_truncated_binary_fails(self):
        self.assert_inspection_fails(self.truncated)

    def test_native_binary_passes(self):
        result = self.check(self.native)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0 strong", result.stdout)

    def test_versioned_library_passes(self):
        result = self.check(self.versioned)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0 strong", result.stdout)

    def test_missing_strong_library_fails(self):
        result = self.check(self.strong)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"STRONG {self.missing_library} is not on this macOS", result.stdout)

    def test_missing_reexported_library_fails(self):
        result = self.check(self.through_umbrella)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"STRONG {self.umbrella} re-exports {self.reexported}, which is not on this macOS", result.stdout)
        self.assertIn("STRONG libumbrella_fixture: _reexported_fixture", result.stdout)

    def test_missing_reexport_of_used_library_fails(self):
        result = self.check(self.umbrella_only)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"STRONG {self.umbrella} re-exports {self.reexported}, which is not on this macOS", result.stdout)

    def test_missing_reexport_of_present_weak_library_fails(self):
        # The umbrella exists, so dyld loads it and then needs what it re-exports.
        result = self.check(self.weak_umbrella)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"STRONG {self.umbrella} re-exports {self.reexported}, which is not on this macOS", result.stdout)

    def test_import_from_shared_short_name_fails(self):
        result = self.assert_inspection_fails(self.ambiguous)
        self.assertIn("a name several linked libraries share", result.stderr)

    def test_missing_library_sharing_a_name_fails(self):
        result = self.check(self.duplicate_names)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"STRONG {self.missing_duplicate} is not on this macOS", result.stdout)

    def test_missing_unreferenced_library_fails(self):
        result = self.check(self.unreferenced)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"STRONG {self.missing_library} is not on this macOS", result.stdout)

    def test_symbol_only_in_other_slice_fails(self):
        result = self.check(self.sliced)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("STRONG libslice_fixture: _slice_fixture", result.stdout)

    def test_missing_weak_library_passes(self):
        result = self.check(self.weak)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"weak   {self.missing_library} is not on this macOS", result.stdout)


if __name__ == "__main__":
    unittest.main()
