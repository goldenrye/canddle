"""Real AVAudioConverter regression checks; no microphone or speaker access."""

import os
import subprocess

import pytest

PROBE = os.environ.get("VPCOMM_AUDIO_PROBE")


@pytest.mark.skipif(not PROBE, reason="Compile native AudioChecks.swift")
def test_native_audio_conversion():
    result = subprocess.run([PROBE], capture_output=True, text=True, timeout=20, check=False)
    assert result.returncode == 0, result.stderr + result.stdout
    assert result.stdout.startswith("PASS audio:")
