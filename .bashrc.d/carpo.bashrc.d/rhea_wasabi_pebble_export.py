#!/usr/bin/env python3
"""Compatibility wrapper for the canonical root exporter module."""
from pathlib import Path
import runpy
runpy.run_path(str(Path(__file__).resolve().parents[2] / "rhea_wasabi_pebble_export.py"), run_name="__main__")
