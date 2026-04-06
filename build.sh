#!/bin/bash
set -e

# Create persistent volume for nix store (survives container restarts)
docker volume create nix-store 2>/dev/null || true

# Build and copy result
docker run --rm -t \
  -v nix-store:/nix \
  -v "$(pwd):/work" \
  -w /work \
  nixos/nix \
  sh -c '
    set -e
    echo "Building NixOS image..."
    OUT=$(nix --extra-experimental-features "nix-command flakes" \
          build ".#images.ahiru" --no-link --print-out-paths)
    echo "Built: $OUT"
    echo "Copying image..."
    cp "$OUT/sd-image/"*.img.zst /work/result.img.zst
    echo "Done! Decompress with: zstd -d result.img.zst -o result.img"
  '

ls -lh result.img.zst
