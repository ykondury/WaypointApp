# idevice build inputs

Run `bash scripts/fetch-idevice.sh` before generating or building the Xcode
project. The script checks out a pinned `idevice` source revision, applies the
location-simulation I/O timeout patch, runs its focused timeout regression test,
and builds `idevice.h` and `libidevice_ffi.a` for arm64 iOS devices. It requires
Xcode command-line tools, Git, Rust, and the `aarch64-apple-ios` Rust target.

The generated files are intentionally ignored by Git. They are produced as part
of the iOS build so the IPA includes the patched native timeout rather than
relying on cancellation of a blocked Swift task.

