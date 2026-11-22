#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
vendor_dir="$root_dir/Vendor/idevice"
source_commit="218977705b8c21d2450c920b14310049ef33752f"
source_dir="$(mktemp -d "${TMPDIR:-/tmp}/waypoint-idevice.XXXXXX")"
trap 'rm -rf "$source_dir"' EXIT

mkdir -p "$vendor_dir"

if [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

if ! command -v cargo >/dev/null 2>&1 || ! command -v rustup >/dev/null 2>&1; then
  echo "Rust and rustup are required to build the patched iOS FFI library." >&2
  exit 1
fi

rustup target add aarch64-apple-ios
git -C "$source_dir" init --quiet
git -C "$source_dir" remote add origin https://github.com/jkcoxson/idevice.git
git -C "$source_dir" fetch --quiet --depth 1 origin "$source_commit"
git -C "$source_dir" checkout --quiet --detach FETCH_HEAD
git -C "$source_dir" apply "$root_dir/patches/idevice-location-simulation-timeout.patch"

# `provider`, `lockdown`, and the DVT RSD helpers are compiled
# unconditionally, so the FFI crate also needs the `xpc`, `tcp`, and
# `usbmuxd` features in addition to the services Waypoint uses.
features="ring,core_device_proxy,dvt,location_simulation,mobile_image_mounter,remote_pairing,rsd,tunnel_tcp_stack,xpc,tcp,usbmuxd"
test_log="$source_dir/timeout-test.log"
cargo test \
  --manifest-path "$source_dir/ffi/Cargo.toml" \
  --locked \
  --no-default-features \
  --features "$features" \
  -- \
  --exact dvt::location_simulation::tests::location_simulation_set_times_out_without_blocking_the_ffi_runtime \
  | tee "$test_log"
grep -Fq 'test result: ok. 1 passed;' "$test_log"

cargo build \
  --manifest-path "$source_dir/ffi/Cargo.toml" \
  --locked \
  --release \
  --target aarch64-apple-ios \
  --no-default-features \
  --features "$features"

header="$source_dir/ffi/idevice.h"
library="$source_dir/target/aarch64-apple-ios/release/libidevice_ffi.a"
if [[ ! -s "$header" || ! -s "$library" ]]; then
  echo "The patched iOS FFI header or static library was not generated." >&2
  exit 1
fi

nm -g "$library" > "$source_dir/symbols.txt"
for symbol in location_simulation_set remote_server_connect_rsd image_mounter_connect_rsd tunnel_create_rppairing; do
  if ! grep -q "_$symbol" "$source_dir/symbols.txt"; then
    echo "The patched FFI archive is missing required symbol: $symbol" >&2
    exit 1
  fi
done

cp "$header" "$vendor_dir/idevice.h"
cp "$library" "$vendor_dir/libidevice_ffi.a"

echo "Patched idevice FFI built for aarch64-apple-ios (source $source_commit)."
shasum -a 256 "$vendor_dir/idevice.h" "$vendor_dir/libidevice_ffi.a"

