#!/usr/bin/env python3
"""Ansible dynamic inventory populated from Terraform outputs."""

import json
import pathlib
import subprocess
import sys


TERRAFORM_DIR = pathlib.Path(__file__).resolve().parents[2] / "terraform"


def main():
    try:
        result = subprocess.run(
            ["terraform", "output", "-json", "nodes"],
            cwd=TERRAFORM_DIR,
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        print(
            f"Terraform executable not found: {error}. Install Terraform and retry.",
            file=sys.stderr,
        )
        return 1

    if result.returncode:
        detail = result.stderr.strip() or "Terraform returned no error details."
        print(
            "Unable to read Terraform output 'nodes'. Initialize Terraform and "
            "apply the VM configuration before running Ansible:\n"
            "  cd terraform && terraform init && terraform apply\n"
            f"\nTerraform reported:\n{detail}",
            file=sys.stderr,
        )
        return result.returncode

    try:
        nodes = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        print(f"Terraform returned invalid JSON for output 'nodes': {error}", file=sys.stderr)
        return 1

    inventory = {
        "_meta": {"hostvars": {}},
        "all": {"children": ["controllers", "workers"]},
        "controllers": {"children": ["controllers_primary", "controllers_additional"]},
        "controllers_primary": {"hosts": []},
        "controllers_additional": {"hosts": []},
        "workers": {"hosts": []},
    }

    for name, node in nodes.items():
        inventory[node["role"]]["hosts"].append(name)
        inventory["_meta"]["hostvars"][name] = {
            "ansible_host": node["ipv4_address"],
            "ansible_user": node["ssh_username"],
            "ansible_ssh_private_key_file": node["ssh_private_key_file"],
        }

    if len(sys.argv) == 3 and sys.argv[1] == "--host":
        print(json.dumps(inventory["_meta"]["hostvars"].get(sys.argv[2], {})))
    else:
        print(json.dumps(inventory))
    return 0


if __name__ == "__main__":
    sys.exit(main())
