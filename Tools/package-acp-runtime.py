#!/usr/bin/env python3
"""Build a portable, credential-free ACP Node runtime package.

The package format matches ``ACPManagedRuntime.manifestFileName``. It copies
only a Node executable, a preinstalled node_modules tree, and an optional entry
file from a dedicated agent source directory. It never installs dependencies,
downloads files, or reads provider login/state directories.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
from typing import Iterable


MANIFEST_NAME = "okamiuni-acp-runtime.json"
MAX_ARGUMENTS = 32
MAX_ARGUMENT_LENGTH = 4096
MAX_DISPLAY_NAME_LENGTH = 128
FORBIDDEN_FILENAMES = {".env", ".npmrc", "credentials", "credential", "secrets", "secret", "id_rsa"}


class PackageError(Exception):
    """A package source does not meet the portable-runtime contract."""


def is_within(candidate: Path, root: Path) -> bool:
    try:
        candidate.relative_to(root)
        return True
    except ValueError:
        return False


def require_directory(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.is_dir():
        raise PackageError(f"{label} must be a real directory: {path}")
    return path.resolve(strict=True)


def require_node_binary(path: Path) -> Path:
    resolved = path.resolve(strict=True)
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise PackageError(f"--node must resolve to an executable regular file: {path}")
    return resolved


def validate_relative_path(value: str, label: str) -> Path:
    path = Path(value)
    if not value or path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise PackageError(f"{label} must be a non-empty relative path without traversal: {value!r}")
    return path


def validate_literal(value: str, label: str) -> str:
    if not value or len(value) > MAX_ARGUMENT_LENGTH or "\x00" in value or "\n" in value or "\r" in value:
        raise PackageError(f"{label} must be a short, single-line literal")
    return value


def contains_forbidden_name(path: Path) -> bool:
    lowered = path.name.lower()
    return lowered in FORBIDDEN_FILENAMES or lowered.startswith(".env.")


def copy_regular_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination, follow_symlinks=False)
    source_mode = stat.S_IMODE(source.stat(follow_symlinks=False).st_mode)
    os.chmod(destination, source_mode)


def copy_node_modules(source_root: Path, destination_root: Path) -> None:
    """Copy a dependency tree with no symlinks in the resulting package.

    Package-manager bin links are common. They are followed only if their final
    target remains inside the canonical source node_modules root; a link that
    escapes is rejected before any package is produced.
    """

    def copy_entry(source: Path, destination: Path, resolution_stack: tuple[Path, ...]) -> None:
        if contains_forbidden_name(source):
            # Credentials and local npm settings are never part of a runtime.
            return

        node = source.lstat()
        if stat.S_ISLNK(node.st_mode):
            try:
                target = source.resolve(strict=True)
            except FileNotFoundError as error:
                raise PackageError(f"broken symlink in node_modules: {source}") from error
            if not is_within(target, source_root):
                raise PackageError(f"symlink escapes node_modules: {source}")
            if target in resolution_stack:
                raise PackageError(f"cyclic symlink in node_modules: {source}")
            copy_entry(target, destination, resolution_stack + (target,))
            return

        if stat.S_ISDIR(node.st_mode):
            destination.mkdir(parents=True, exist_ok=True)
            os.chmod(destination, stat.S_IMODE(node.st_mode))
            for child in sorted(source.iterdir(), key=lambda item: item.name):
                copy_entry(child, destination / child.name, resolution_stack)
            return

        if stat.S_ISREG(node.st_mode):
            copy_regular_file(source, destination)
            return

        raise PackageError(f"unsupported file type in node_modules: {source}")

    copy_entry(source_root, destination_root, (source_root,))


def copy_entry_file(source_root: Path, entry: Path, destination_root: Path) -> str | None:
    if not entry:
        return None
    source = source_root / entry
    try:
        resolved = source.resolve(strict=True)
    except FileNotFoundError as error:
        raise PackageError(f"--entry must identify a regular file under --source-root: {entry}") from error
    if source != resolved or not is_within(resolved, source_root) or not source.is_file():
        raise PackageError(f"--entry must identify a regular file under --source-root: {entry}")
    if contains_forbidden_name(source):
        raise PackageError(f"--entry cannot be a credentials or environment file: {entry}")
    copy_regular_file(source, destination_root / "agent" / entry)
    return (Path("agent") / entry).as_posix()


def parse_arguments(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Package a preinstalled Node ACP adapter without provider login state."
    )
    parser.add_argument("--runtime-name", required=True, help="Display name written to the runtime manifest")
    parser.add_argument("--node", required=True, type=Path, help="Path to the Node executable")
    parser.add_argument("--source-root", required=True, type=Path, help="Dedicated adapter source directory")
    parser.add_argument("--node-modules", required=True, type=Path, help="Preinstalled node_modules under --source-root")
    parser.add_argument("--entry", help="Optional relative adapter entry file under --source-root")
    parser.add_argument("--node-argument", action="append", default=[], help="Literal Node argument before --entry")
    parser.add_argument("--agent-argument", action="append", default=[], help="Literal agent argument after --entry")
    parser.add_argument("--output", required=True, type=Path, help="New destination directory for the package")
    return parser.parse_args(list(argv))


def package_runtime(arguments: argparse.Namespace) -> Path:
    runtime_name = validate_literal(arguments.runtime_name, "--runtime-name")
    if len(runtime_name) > MAX_DISPLAY_NAME_LENGTH:
        raise PackageError("--runtime-name is too long")

    source_root = require_directory(arguments.source_root, "--source-root")
    node_modules_input = arguments.node_modules.absolute()
    node_modules = require_directory(node_modules_input, "--node-modules")
    if not is_within(node_modules, source_root):
        raise PackageError("--node-modules must be inside --source-root")
    node_binary = require_node_binary(arguments.node)

    entry = validate_relative_path(arguments.entry, "--entry") if arguments.entry else None
    node_arguments = [validate_literal(value, "--node-argument") for value in arguments.node_argument]
    agent_arguments = [validate_literal(value, "--agent-argument") for value in arguments.agent_argument]
    if len(node_arguments) + len(agent_arguments) + (1 if entry else 0) > MAX_ARGUMENTS:
        raise PackageError("the manifest supports at most 32 arguments")

    output = arguments.output.expanduser().resolve(strict=False)
    if output.exists() or output.is_symlink():
        raise PackageError(f"--output must not already exist: {output}")
    if is_within(output, source_root) or is_within(output, node_modules):
        raise PackageError("--output cannot be inside a copied source directory")
    if output.parent.is_symlink():
        raise PackageError("--output parent cannot be a symlink")

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.tmp-", dir=output.parent))
    try:
        copy_regular_file(node_binary, temporary / "runtime" / "node")
        copy_node_modules(node_modules, temporary / "agent" / "node_modules")
        packaged_entry = copy_entry_file(source_root, entry, temporary)
        manifest_arguments = node_arguments + ([packaged_entry] if packaged_entry else []) + agent_arguments
        manifest = {
            "schemaVersion": 1,
            "displayName": runtime_name,
            "executable": "runtime/node",
            "arguments": manifest_arguments,
            "environment": {},
        }
        (temporary / MANIFEST_NAME).write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return output


def main(argv: Iterable[str] | None = None) -> int:
    try:
        destination = package_runtime(parse_arguments(sys.argv[1:] if argv is None else argv))
    except (PackageError, OSError, ValueError) as error:
        print(f"package-acp-runtime: {error}", file=sys.stderr)
        return 2
    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
