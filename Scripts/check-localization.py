"""Check the catalog against Xcode's extracted strings; --patch prints an apply_patch patch."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--patch", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
catalog = root / "CannyGit/Resources/Localizable.xcstrings"
original = catalog.read_text()
document = json.loads(original)
extracted = root / "DerivedData/Build/Intermediates.noindex/CannyGit.build/Debug/CannyGit.build/Objects-normal/arm64"
files = list(extracted.glob("*.stringsdata"))
if not files:
    raise SystemExit("Build the Debug app before checking localization.")
keys = set()
for file in files:
    payload = json.loads(file.read_text())
    keys.update(item["key"] for item in payload.get("tables", {}).get("Localizable", []))
missing = sorted(keys - document["strings"].keys())
if args.patch and missing:
    for key in missing:
        document["strings"][key] = {}
    updated = json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    print("*** Begin Patch\n*** Update File: CannyGit/Resources/Localizable.xcstrings\n@@")
    print("\n".join("-" + line for line in original.splitlines()))
    print("\n".join("+" + line for line in updated.splitlines()))
    print("*** End Patch")
elif missing:
    print("Missing catalog entries:")
    print("\n".join(missing))
    raise SystemExit(1)
else:
    print(f"Localization catalog covers {len(keys)} extracted keys.")
