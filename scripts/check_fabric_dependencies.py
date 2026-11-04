"""Check that promoted Fabric items have what they depend on in the target branch.

Run from the promotion branch's working tree (target branch + promoted items).
Three checks:

1. logicalId references (warning): Fabric Git integration stores a referenced
   item's logicalId (e.g. a pipeline's notebookId). A logicalId that is defined
   on the source branch but missing from the working tree is reported.
2. %run / notebook.run("name") references:
   - blocking error when <name>.Notebook does not exist in the working tree;
   - warning when it exists but differs from the source branch's version
     (the promoted item may need the newer version, e.g. a new function in a shared helper notebook).
3. Pipeline libraryVariables.<name> references (blocking error) when <name> is
   not declared in any VariableLibrary variables.json in the working tree.

Not detected: references built at run time (e.g. notebook.runMultiple(dag), or
a notebook reading the variable library through a constant), and
workspace-specific GUIDs such as a notebook's default lakehouse.

Exit code 1 when there is at least one blocking error; the report file is
written either way.
"""

import argparse
import json
import re
import subprocess
from pathlib import Path

GUID_PATTERN = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
RUN_PATTERNS = (
    re.compile(r"^\s*%run\s+(\S+)", re.MULTILINE),
    re.compile(r"""notebook\.run\(\s*["']([^"']+)["']"""),
)
LIBRARY_VARIABLE_PATTERN = re.compile(r"libraryVariables\.([A-Za-z0-9_]+)")


def run_git(*arguments: str) -> str:
    return subprocess.run(
        ["git", *arguments], check=True, capture_output=True, text=True
    ).stdout


def git_succeeds(*arguments: str) -> bool:
    return subprocess.run(["git", *arguments], capture_output=True).returncode == 0


def is_platform_file(file_path: str) -> bool:
    return file_path == ".platform" or file_path.endswith("/.platform")


def item_folder_of(platform_path: str) -> str:
    return platform_path.rsplit("/.platform", 1)[0] if "/" in platform_path else "."


def read_platform_file(platform_text: str) -> tuple[str, str] | None:
    """Return (logical_id, display_label) from .platform JSON, or None."""
    try:
        platform_content = json.loads(platform_text)
    except json.JSONDecodeError:
        return None
    logical_id = platform_content.get("config", {}).get("logicalId")
    metadata = platform_content.get("metadata", {})
    if not logical_id:
        return None
    display_label = f"{metadata.get('displayName', '?')}.{metadata.get('type', '?')}"
    return logical_id.lower(), display_label


def source_branch_items(source_reference: str) -> dict[str, tuple[str, str]]:
    """Map logicalId -> (item folder, display label) for every item on the source branch."""
    items_by_logical_id = {}
    for file_path in run_git("ls-tree", "-r", "--name-only", source_reference).splitlines():
        if not is_platform_file(file_path):
            continue
        parsed = read_platform_file(run_git("show", f"{source_reference}:{file_path}"))
        if parsed:
            logical_id, display_label = parsed
            items_by_logical_id[logical_id] = (item_folder_of(file_path), display_label)
    return items_by_logical_id


def working_tree_items() -> tuple[set[str], dict[str, str]]:
    """(logicalIds, item folder name -> folder path) for the working tree."""
    logical_ids = set()
    folders_by_name = {}
    for file_path in run_git("ls-files").splitlines():
        if not is_platform_file(file_path) or not Path(file_path).exists():
            continue
        item_folder = item_folder_of(file_path)
        folders_by_name[item_folder.rsplit("/", 1)[-1]] = item_folder
        parsed = read_platform_file(Path(file_path).read_text(encoding="utf-8", errors="ignore"))
        if parsed:
            logical_ids.add(parsed[0])
    return logical_ids, folders_by_name


def working_tree_library_variables() -> set[str]:
    names = set()
    for file_path in run_git("ls-files").splitlines():
        if file_path.endswith(".VariableLibrary/variables.json") and Path(file_path).exists():
            try:
                content = json.loads(Path(file_path).read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                continue
            names.update(v.get("name") for v in content.get("variables", []))
    return names


def item_texts(item_folder: str) -> list[str]:
    folder_path = Path(item_folder)
    if not folder_path.exists():
        return []
    return [
        file_path.read_text(encoding="utf-8", errors="ignore")
        for file_path in folder_path.rglob("*")
        if file_path.is_file() and file_path.name != ".platform"
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-reference", required=True)
    parser.add_argument("--report-file", required=True)
    parser.add_argument("item_folders", nargs="+")
    arguments = parser.parse_args()
    source = arguments.source_reference

    items_on_source = source_branch_items(source)
    present_logical_ids, folders_by_name = working_tree_items()
    library_variables = working_tree_library_variables()

    errors, warnings = [], []

    def error(message: str) -> None:
        errors.append(f"- :x: {message}")
        print(f"::error::{message}")

    def warning(message: str) -> None:
        warnings.append(f"- :warning: {message}")
        print(f"::warning::{message}")

    for item_folder in arguments.item_folders:
        texts = item_texts(item_folder)

        # 1. logicalId references
        referenced_ids = {m.lower() for text in texts for m in GUID_PATTERN.findall(text)}
        for referenced_id in sorted(referenced_ids):
            if referenced_id in items_on_source and referenced_id not in present_logical_ids:
                dependency_folder, dependency_label = items_on_source[referenced_id]
                warning(
                    f"`{item_folder}` references `{dependency_label}` "
                    f"(`{dependency_folder}`), which is not on the target branch. Consider promoting it too."
                )

        # 2. %run / notebook.run references
        run_targets = {
            m.rsplit("/", 1)[-1] for text in texts for p in RUN_PATTERNS for m in p.findall(text)
        }
        for notebook_name in sorted(run_targets):
            dependency_folder = folders_by_name.get(f"{notebook_name}.Notebook")
            if dependency_folder is None:
                error(
                    f"`{item_folder}` runs `{notebook_name}`, but `{notebook_name}.Notebook` "
                    f"is not on the target branch. Add it to the item list."
                )
            elif (
                dependency_folder not in arguments.item_folders
                and git_succeeds("cat-file", "-e", f"{source}:{dependency_folder}")
                and not git_succeeds("diff", "--cached", "--quiet", source, "--", dependency_folder)
            ):
                warning(
                    f"`{item_folder}` runs `{notebook_name}`, which differs between the source "
                    f"and target branches. If the promoted item needs the source's version, "
                    f"add `{notebook_name}.Notebook` to the item list."
                )

        # 3. pipeline libraryVariables references
        variable_names = {m for text in texts for m in LIBRARY_VARIABLE_PATTERN.findall(text)}
        for variable_name in sorted(variable_names - library_variables):
            error(
                f"`{item_folder}` uses library variable `{variable_name}`, which is not declared "
                f"in the target branch's Variable Library. Promote the Variable Library change too."
            )

    report_lines = errors + warnings or [
        "- No missing dependencies detected (references built at run time, such as "
        "`notebook.runMultiple`, and workspace-specific IDs are not checked)."
    ]
    Path(arguments.report_file).write_text("\n".join(report_lines) + "\n", encoding="utf-8")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
