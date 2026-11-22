import Foundation
import IDevice

extension DeviceBridge {
    func mountedImageCount() throws -> Int {
        guard let adapter, let handshake else {
            throw DeviceBridgeError.message("The developer tunnel is not connected.")
        }

        var mounter: OpaquePointer?
        try consume(
            image_mounter_connect_rsd(adapter, handshake, &mounter),
            fallback: "Could not connect to the developer image service."
        )
        guard let mounter else {
            throw DeviceBridgeError.message("The developer image service did not return a client.")
        }
        defer { image_mounter_free(mounter) }

        var devices: UnsafeMutablePointer<plist_t?>?
        var count = 0
        try consume(
            image_mounter_copy_devices(mounter, &devices, &count),
            fallback: "Could not check whether the developer image is mounted."
        )

        if let devices { idevice_plist_array_free(devices, UInt(count)) }
        return count
    }

    func mountDeveloperImageSynchronously(_ paths: DeveloperImagePaths) throws {
        guard let adapter, let handshake else {
            throw DeviceBridgeError.message("The developer tunnel is not connected.")
        }

        let image = try mappedData(at: paths.image, label: "developer image")
        let trustCache = try mappedData(at: paths.trustCache, label: "trust cache")
        let manifest = try mappedData(at: paths.buildManifest, label: "build manifest")

        var lockdown: OpaquePointer?
        try consume(
            lockdownd_connect_rsd(adapter, handshake, &lockdown),
            fallback: "Could not connect to lockdownd."
        )
        guard let lockdown else {
            throw DeviceBridgeError.message("Lockdownd did not return a client.")
        }
        defer { lockdownd_client_free(lockdown) }

        var chipIDNode: plist_t?
        try consume(
            lockdownd_get_value(lockdown, "UniqueChipID", nil, &chipIDNode),
            fallback: "Could not read this iPhone's chip identifier."
        )
        guard let chipIDNode else {
            throw DeviceBridgeError.message("The chip identifier was missing from the device response.")
        }
        defer { plist_free(chipIDNode) }

        var uniqueChipID: UInt64 = 0
        plist_get_uint_val(chipIDNode, &uniqueChipID)
        guard uniqueChipID != 0 else {
            throw DeviceBridgeError.message("The chip identifier could not be decoded.")
        }

        var mounter: OpaquePointer?
        try consume(
            image_mounter_connect_rsd(adapter, handshake, &mounter),
            fallback: "Could not connect to the developer image service."
        )
        guard let mounter else {
            throw DeviceBridgeError.message("The developer image service did not return a client.")
        }
        defer { image_mounter_free(mounter) }

        let mountError: UnsafeMutablePointer<IdeviceFfiError>? = image.withUnsafeBytes { imageBytes in
            trustCache.withUnsafeBytes { trustBytes in
                manifest.withUnsafeBytes { manifestBytes in
                    image_mounter_mount_personalized_rsd(
                        mounter,
                        adapter,
                        handshake,
                        imageBytes.bindMemory(to: UInt8.self).baseAddress,
                        image.count,
                        trustBytes.bindMemory(to: UInt8.self).baseAddress,
                        trustCache.count,
                        manifestBytes.bindMemory(to: UInt8.self).baseAddress,
                        manifest.count,
                        nil,
                        uniqueChipID
                    )
                }
            }
        }
        try consume(mountError, fallback: "The personalized developer image could not be mounted.")
    }

    private func mappedData(at url: URL, label: String) throws -> Data {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else {
                throw DeviceBridgeError.message("The \(label) file is empty.")
            }
            return data
        } catch let error as DeviceBridgeError {
            throw error
        } catch {
            throw DeviceBridgeError.message("Could not read the \(label): \(error.localizedDescription)")
        }
    }
}
