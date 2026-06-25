"""
Weekly workflow export/drift-check (Phase 3 leftover).

Exports the live state of every workflow from the running n8n instance via its CLI,
compares each known workflow against its hand-authored file in workflows/, and
overwrites the repo file only if something *meaningful* actually drifted (a live UI
edit that never got backported to git) -- volatile fields that always differ
(timestamps, versionId, isArchived, description, active-state, meta) are excluded
from the comparison so this doesn't create noise on every run.

Usage (from the repo root, with the stack running):
    python3 scripts/sync_workflows.py
Exits 0 with "no drift detected" if nothing changed. Does not commit or push --
that's left to the caller (see scripts/sync_workflows.ps1) so a human/CI step can
review the diff first if desired.
"""

import json
import subprocess
import sys
import tempfile
import os

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS_DIR = os.path.join(REPO_ROOT, "workflows")

# id -> repo-relative filename, for every workflow that's actually tracked in git.
# Anything exported that isn't in this map (stray test workflows, WF-6 once it
# exists and gets added here, etc.) is silently ignored.
KNOWN = {
    "fb2f353f1fad491e": "wf0_selftest.json",
    "75a4a1a8497c48f0": "wf1_collect_ats.json",
    "b1b5e0f3a2b4d6789": "wf1b_collect_aggregators.json",
    "c1c5e0f3a2b4d6789": "wf1c_collect_pages.json",
    "d15c0f3a2b4e6789": "wf1d_discover.json",
    "c4f8a29d1e6b3075": "wf2_score.json",
    "9b3e7f42a8d15c60": "wf3_notify.json",
    "f4a1b2c3d4e5f678": "wf4_gmail.json",
    "5e11a1a2b3c4d5e6": "wf5_error.json",
    "8e45da373fd94a90": "wf_l0_config.json",
    "773d1f4a0f6b4bf7": "wf_l1_normalize.json",
}

# Every hand-authored file in this repo only ever uses these top-level keys.
# n8n's export additionally includes internal bookkeeping (timestamps, project/
# owner IDs under "shared", versioning counters, etc.) that doesn't belong in
# git and isn't stable across exports -- keep an allow-list, not a deny-list,
# so a newly-added n8n-internal field can't silently leak into a commit.
KEEP_KEYS = ["id", "name", "nodes", "connections", "active", "settings", "pinData"]

# "active" is excluded from drift comparison (see below) since the repo's own
# convention deliberately differs from live DB state for dormant collectors.
COMPARE_KEYS = [k for k in KEEP_KEYS if k != "active"]


def normalize(wf):
    return {k: wf.get(k) for k in COMPARE_KEYS}


def main():
    with tempfile.TemporaryDirectory():
        subprocess.run(["docker", "compose", "exec", "-T", "n8n", "sh", "-c",
                         "rm -rf /home/node/workflows_export_tmp && mkdir -p /home/node/workflows_export_tmp"],
                        cwd=REPO_ROOT, check=True)
        result = subprocess.run(
            ["docker", "compose", "exec", "-T", "n8n", "n8n",
             "export:workflow", "--backup", "--output=/home/node/workflows_export_tmp/"],
            cwd=REPO_ROOT, capture_output=True, text=True,
        )
        if result.returncode != 0:
            print("export:workflow failed:", result.stdout, result.stderr, file=sys.stderr)
            sys.exit(1)
        print(result.stdout.strip())

        changed = []
        for wf_id, filename in KNOWN.items():
            cat = subprocess.run(
                ["docker", "compose", "exec", "-T", "n8n", "sh", "-c",
                 f"cat /home/node/workflows_export_tmp/{wf_id}.json 2>/dev/null || true"],
                cwd=REPO_ROOT, capture_output=True, text=True,
            )
            if not cat.stdout.strip():
                print(f"  (skip {filename} -- not found live, was it deleted in the UI?)")
                continue
            exported = json.loads(cat.stdout)
            repo_path = os.path.join(WORKFLOWS_DIR, filename)
            with open(repo_path, encoding="utf-8") as f:
                repo_wf = json.load(f)

            if normalize(exported) != normalize(repo_wf):
                # Keep only the fields this repo's hand-authored files ever use.
                # "active" preserves the repo's own convention (dormant
                # collectors stay `active: false` in git regardless of live state).
                merged = {k: exported.get(k) for k in KEEP_KEYS}
                merged["active"] = repo_wf.get("active", False)
                if merged.get("pinData") is None:
                    merged["pinData"] = repo_wf.get("pinData", {})
                with open(repo_path, "w", encoding="utf-8", newline="\n") as f:
                    json.dump(merged, f, indent=2, ensure_ascii=False)
                    f.write("\n")
                changed.append(filename)

        subprocess.run(["docker", "compose", "exec", "-T", "n8n", "sh", "-c",
                         "rm -rf /home/node/workflows_export_tmp"],
                        cwd=REPO_ROOT)

        if changed:
            print("Drift detected and synced into these files:")
            for f in changed:
                print("  -", f)
            sys.exit(2)  # distinct exit code so the caller knows there's something to commit
        else:
            print("No drift detected -- every tracked workflow matches its live definition.")
            sys.exit(0)


if __name__ == "__main__":
    main()
