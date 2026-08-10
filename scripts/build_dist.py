#!/usr/bin/env python3
"""
Build and package distribution archive.

Creates a ZIP file containing:
  - ansible/ folder
  - bootstrap.sh
  - README.md

Archive filename is derived from pyproject.toml:
  {project_name}_v_{project_version}.zip

The archive is placed in the dist/ directory at repo root.
"""

import sys
import tomllib
import zipfile
from pathlib import Path
from typing import Any


def load_pyproject(pyproject_path: Path) -> dict[str, Any]:
    """Load project metadata from pyproject.toml."""
    with open(pyproject_path, "rb") as f:
        data = tomllib.load(f)
    return data.get("project", {})


def add_directory_to_zip(zip_file: zipfile.ZipFile, dir_path: Path, arcname: str = "") -> None:
    """Recursively add a directory to the ZIP file, preserving structure."""
    for item in dir_path.iterdir():
        item_arcname = f"{arcname}/{item.name}" if arcname else item.name
        if item.is_dir():
            add_directory_to_zip(zip_file, item, item_arcname)
        else:
            zip_file.write(item, arcname=item_arcname)


def build_archive(repo_root: Path) -> None:
    """Build the distribution archive."""
    # Load project metadata
    pyproject_path = repo_root / "pyproject.toml"
    if not pyproject_path.exists():
        print(f"Error: {pyproject_path} not found", file=sys.stderr)
        sys.exit(1)

    project_meta = load_pyproject(pyproject_path)
    name = str(project_meta.get("name"))
    version = str(project_meta.get("version"))

    if not name or not version:
        print(f"Error: 'name' or 'version' not found in {pyproject_path}", file=sys.stderr)
        sys.exit(1)

    # Create dist directory
    dist_dir = repo_root / "dist"
    dist_dir.mkdir(exist_ok=True)

    # Define archive filename
    archive_name = f"{name}_v_{version}.zip"
    archive_path = dist_dir / archive_name

    # Define files to include
    files_to_pack = [
        repo_root / "ansible",
        repo_root / "bootstrap.sh",
        repo_root / "README.md",
    ]

    # Verify all files exist
    for file_path in files_to_pack:
        if not file_path.exists():
            print(f"Error: {file_path} not found", file=sys.stderr)
            sys.exit(1)

    # Create the ZIP archive
    print(f"Creating {archive_path}...")
    with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for item in files_to_pack:
            if item.is_dir():
                add_directory_to_zip(zf, item, arcname=item.name)
            else:
                zf.write(item, arcname=item.name)

    print(f"✓ Distribution archive created: {archive_path}")
    print(f"  Name: {archive_name}")
    print(f"  Size: {archive_path.stat().st_size} bytes")


if __name__ == "__main__":
    repo_root = Path(__file__).parent.parent
    build_archive(repo_root)
