#!/usr/bin/python3
"""Run apt-get in the background and report its progress in the GTK main loop."""
import os
import subprocess
import threading

from gi.repository import GLib


class AptCommand():
    """Runs "apt-get <args>" non-interactively.

    on_progress(percent, description) is called during the run and
    on_finished(success, errors) once it's done, both in the main loop.
    """

    def __init__(self, args, on_progress=None, on_finished=None):
        self.args = args
        self.on_progress = on_progress
        self.on_finished = on_finished

    def run(self):
        read_fd, write_fd = os.pipe()
        command = ["apt-get", "--quiet", "--yes",
                   "-o", "APT::Status-Fd=%d" % write_fd,
                   "-o", "Dpkg::Options::=--force-confdef",
                   "-o", "Dpkg::Options::=--force-confold"] + self.args
        env = dict(os.environ, DEBIAN_FRONTEND="noninteractive", APT_LISTCHANGES_FRONTEND="none")
        try:
            process = subprocess.Popen(command, pass_fds=(write_fd,), env=env, text=True,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as e:
            os.close(read_fd)
            os.close(write_fd)
            GLib.idle_add(self._finished, False, [str(e)])
            return
        os.close(write_fd)
        status_thread = threading.Thread(target=self._read_status, args=(read_fd,), daemon=True)
        status_thread.start()
        threading.Thread(target=self._wait, args=(process, status_thread), daemon=True).start()

    def _read_status(self, fd):
        with os.fdopen(fd, encoding="utf-8", errors="replace") as status:
            for line in status:
                # dlstatus:<file>:<percent>:<description> or pmstatus:<package>:<percent>:<description>
                fields = line.rstrip("\n").split(":", 3)
                if len(fields) == 4 and fields[0] in ("dlstatus", "pmstatus"):
                    try:
                        percent = float(fields[2])
                    except ValueError:
                        continue
                    GLib.idle_add(self._progress, percent, fields[3])

    def _wait(self, process, status_thread):
        stdout, stderr = process.communicate()
        status_thread.join()
        errors = [line for line in stderr.splitlines() if line.startswith(("E:", "W:", "Err:"))]
        errors += [line for line in stdout.splitlines() if line.startswith("Err:")]
        if process.returncode != 0 and not errors:
            errors = stderr.strip().splitlines()[-5:] or ["apt-get exited with status %d" % process.returncode]
        GLib.idle_add(self._finished, process.returncode == 0, errors)

    def _progress(self, percent, description):
        if self.on_progress is not None:
            self.on_progress(percent, description)
        return False

    def _finished(self, success, errors):
        if self.on_finished is not None:
            self.on_finished(success, errors)
        return False
