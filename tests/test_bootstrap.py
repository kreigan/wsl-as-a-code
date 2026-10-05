from docker import DockerClient
from pathlib import Path
from testcontainers.core.container import DockerContainer
from typing import cast

import pytest
import sys


bootstrap_script = "/root/execute.sh"


class ArchLinuxContainer(DockerContainer):
  """Arch Linux Docker container with streaming command execution."""

  def __init__(self, command: str = "sleep infinity") -> None:
    super().__init__("archlinux:latest", command=command)

  def exec_stream(self, cmd: list[str]) -> int:
    """Execute a command in the container and stream its output to stdout.

    Args:
        cmd (list[str]): The command to execute.

    Returns:
        int: The exit code of the command.
    """

    container_id = self.get_container_id()
    client = cast(DockerClient, self.get_wrapped_container().client)
    exec_id: str = client.api.exec_create(container_id, cmd)['Id'] # pyright: ignore[reportUnknownMemberType]
    
    for chunk in client.api.exec_start(exec_id, stream=True):
      sys.stdout.buffer.write(chunk)
      sys.stdout.flush()
    
    return client.api.exec_inspect(exec_id)['ExitCode']


@pytest.fixture(scope="session")
def arch():
   with ArchLinuxContainer() as container:
     # Fix occasional pacman timeouts in tests
     container.exec([
       "bash", "-c",
       "echo -e '[options]\nXferCommand = /usr/bin/curl --connect-timeout=20 --retry=3 -sfkZLC - -o %o %u' >> /etc/pacman.conf"
     ])
     container.copy_into_container(Path("scripts", "execute.sh"), bootstrap_script, 777)
     yield container


def test_bootstrap(arch: ArchLinuxContainer) -> None:
  exit_code = arch.exec_stream(["bash", bootstrap_script, "bootstrap"])
  assert exit_code == 0

def test_bootstrap_run_playbook(arch: ArchLinuxContainer, tmp_path: Path) -> None:
  playbook = tmp_path / "test_playbook.yml"
  playbook.write_text(
    """---
- name: Test playbook
  hosts: localhost
  gather_facts: false
  vars:
    ansible_python_interpreter: /usr/sbin/python3
  tasks:
    - name: Create test file
      ansible.builtin.copy:
        content: "{{ test_file_content }}"
        dest: "{{ test_file_path }}"
        mode: '0644'
""",
    encoding="utf-8",
  )

  playbook_path = "/root/test_playbook.yml"
  arch.copy_into_container(playbook, playbook_path, 644)

  test_file_content = "This is a test"
  test_file_path = "/tmp/test-bootstrap-script.txt"
  
  arch.exec_stream(["bash", bootstrap_script, "bootstrap"])
  exit_code = arch.exec_stream([
    "bash",
    bootstrap_script,
    "playbook", playbook_path,
    "--extra-vars", f"test_file_path={test_file_path}",
    "--extra-vars", f"test_file_content={test_file_content}"
  ])
  
  assert exit_code == 0
