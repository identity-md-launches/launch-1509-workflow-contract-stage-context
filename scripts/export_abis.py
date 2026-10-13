#!/usr/bin/env python3
"""Export or check the four reviewed contract ABIs after `forge build` (stdlib only)."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if an ABI export is absent or stale")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    names = ("LaunchToken", "Ponziramid", "StoneVault", "PonziRewards")
    for name in names:
        artifact = root / "out" / f"{name}.sol" / f"{name}.json"
        if not artifact.is_file():
            raise SystemExit(f"Missing {artifact.relative_to(root)}; run forge build first")
        abi = json.loads(artifact.read_text())["abi"]
        output = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not output.is_file() or json.loads(output.read_text()) != abi:
                raise SystemExit(f"ABI export is missing or stale: {output.relative_to(root)}")
            print(f"Checked {output.relative_to(root)}")
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(abi, indent=2) + "\n")
            print(f"Exported {output.relative_to(root)}")


if __name__ == "__main__":
    main()
