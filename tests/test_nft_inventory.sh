#!/bin/bash
# Keep parser/inventory tests in the existing shell suite entry.
set -u
cd "$(dirname "$0")/.." || exit 1
exec python3 tests/test_nft_inventory.py
