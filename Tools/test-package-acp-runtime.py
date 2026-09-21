#!/usr/bin/env python3
"""Offline fixtures for Tools/package-acp-runtime.py."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("package-acp-runtime.py")
SPEC = importlib.util.spec_from_file_location("package_acp_runtime", SCRIPT)
assert SPEC and SPEC.loader
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)


class PackageACPNodeRuntimeTests(unittest.TestCase):
    def make_fixture(self, root: Path) -> tuple[Path, Path, Path]:
        source = root / "adapter"
        modules = source / "node_modules"
        modules.mkdir(parents=True)
        node = root / "node"
        node.write_bytes(b"fixture-node")
        node.chmod(0o755)
        (source / "agent.mjs").write_text("export default 'fixture';\n", encoding="utf-8")
        package = modules / "fixture-package"
        package.mkdir()
        (package / "index.js").write_text("module.exports = 'fixture';\n", encoding="utf-8")
        (modules / ".bin").mkdir()
        (modules / ".bin" / "fixture-agent").symlink_to("../fixture-package/index.js")
        (package / ".npmrc").write_text("//registry.example/:_authToken=never-copy\n", encoding="utf-8")
        return source, modules, node

    def command(self, source: Path, modules: Path, node: Path, output: Path) -> list[str]:
        return [
            "--runtime-name", "Fixture ACP",
            "--node", str(node),
            "--source-root", str(source),
            "--node-modules", str(modules),
            "--entry", "agent.mjs",
            "--node-argument=--no-warnings",
            "--agent-argument=--acp",
            "--output", str(output),
        ]

    def test_packages_only_runtime_dependencies_and_relative_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, modules, node = self.make_fixture(root)
            output = root / "Fixture.acp-runtime"

            self.assertEqual(PACKAGER.main(self.command(source, modules, node, output)), 0)

            manifest = json.loads((output / "okamiuni-acp-runtime.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["executable"], "runtime/node")
            self.assertEqual(manifest["arguments"], ["--no-warnings", "agent/agent.mjs", "--acp"])
            self.assertEqual(manifest["environment"], {})
            self.assertTrue((output / "runtime" / "node").is_file())
            self.assertTrue((output / "runtime" / "node").stat().st_mode & stat.S_IXUSR)
            copied_link = output / "agent" / "node_modules" / ".bin" / "fixture-agent"
            self.assertTrue(copied_link.is_file())
            self.assertFalse(copied_link.is_symlink())
            self.assertFalse((output / "agent" / "node_modules" / "fixture-package" / ".npmrc").exists())

    def test_rejects_node_modules_symlink_that_escapes_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, modules, node = self.make_fixture(root)
            outside = root / "outside.js"
            outside.write_text("outside", encoding="utf-8")
            (modules / "fixture-package" / "escape").symlink_to(outside)
            output = root / "Unsafe.acp-runtime"

            self.assertEqual(PACKAGER.main(self.command(source, modules, node, output)), 2)
            self.assertFalse(output.exists())

    def test_rejects_entry_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, modules, node = self.make_fixture(root)
            output = root / "Traversal.acp-runtime"
            command = self.command(source, modules, node, output)
            command[command.index("--entry") + 1] = "../outside.js"

            self.assertEqual(PACKAGER.main(command), 2)
            self.assertFalse(output.exists())

    def test_rejects_entry_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, modules, node = self.make_fixture(root)
            outside = root / "outside.mjs"
            outside.write_text("outside", encoding="utf-8")
            (source / "agent.mjs").unlink()
            (source / "agent.mjs").symlink_to(outside)
            output = root / "Symlink.acp-runtime"

            self.assertEqual(PACKAGER.main(self.command(source, modules, node, output)), 2)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
