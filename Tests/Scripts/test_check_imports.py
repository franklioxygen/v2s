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

    @staticmethod
    def compile(*args):
        """Compile only the generated fixtures with Apple's fixed tool path."""
        command = ["/usr/bin/xcrun", "clang", *map(str, args)]
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

    def test_missing_strong_library_fails(self):
        result = self.check(self.strong)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"STRONG {self.missing_library} is not on this macOS", result.stdout)

    def test_missing_weak_library_passes(self):
        result = self.check(self.weak)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"weak   {self.missing_library} is not on this macOS", result.stdout)


if __name__ == "__main__":
    unittest.main()
