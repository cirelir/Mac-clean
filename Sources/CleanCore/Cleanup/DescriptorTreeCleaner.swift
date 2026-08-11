import Darwin
import Foundation

enum DescriptorCleanupOutcome {
    case success(estimatedDeletedBytes: UInt64)
    case partial(estimatedDeletedBytes: UInt64, message: String)
    case failed(message: String)
    case skipped(CleanupSkipReason)
}

struct DescriptorTreeCleaner {
    let hooks: CleanupExecutionHooks

    func deleteContents(
        at rootURL: URL,
        expectedFingerprint: FileFingerprint,
        action: CleanupAction,
        item: CleanupPlanItem
    ) -> DescriptorCleanupOutcome {
        let rootDescriptor: Int32
        do {
            rootDescriptor = try openCanonicalDirectory(at: rootURL)
        } catch DescriptorCleanupError.pathRejected {
            return .skipped(.pathRejected)
        } catch DescriptorCleanupError.posix(_, _, let code) where code == ENOENT {
            return .skipped(.fingerprintChanged)
        } catch {
            return .failed(message: String(describing: error))
        }
        defer { Darwin.close(rootDescriptor) }

        var rootStatus = stat()
        guard Darwin.fstat(rootDescriptor, &rootStatus) == 0 else {
            return .failed(
                message: posixMessage("fstat root", path: rootURL.path, code: errno)
            )
        }
        guard fingerprint(from: rootStatus) == expectedFingerprint else {
            return .skipped(.fingerprintChanged)
        }
        guard action == .deleteContentsPreservingRoot else {
            return .skipped(.unsupportedAction)
        }

        var progress = DeletionProgress()
        do {
            try hooks.afterRootOpenedAndFingerprinted?(item)
            try removeContents(
                of: rootDescriptor,
                rootDevice: rootStatus.st_dev,
                relativePath: "",
                progress: &progress
            )
            return .success(estimatedDeletedBytes: progress.estimatedDeletedBytes)
        } catch {
            let message = String(describing: error)
            if progress.deletedAnyEntry {
                return .partial(
                    estimatedDeletedBytes: progress.estimatedDeletedBytes,
                    message: message
                )
            }
            return .failed(message: message)
        }
    }

    private func openCanonicalDirectory(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw DescriptorCleanupError.pathRejected
            }
            throw DescriptorCleanupError.posix(
                operation: "open canonical root",
                path: url.path,
                code: errno
            )
        }
        return descriptor
    }

    private func removeContents(
        of directoryDescriptor: Int32,
        rootDevice: dev_t,
        relativePath: String,
        progress: inout DeletionProgress
    ) throws {
        let names = try entryNames(in: directoryDescriptor, relativePath: relativePath)

        for name in names {
            let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            var entryStatus = stat()
            guard fstatat(
                directoryDescriptor,
                name,
                &entryStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw DescriptorCleanupError.posix(
                    operation: "fstatat",
                    path: childPath,
                    code: errno
                )
            }
            guard entryStatus.st_dev == rootDevice else {
                throw DescriptorCleanupError.crossDeviceBoundary(path: childPath)
            }

            if isDirectory(entryStatus) {
                try removeDirectory(
                    named: name,
                    initialStatus: entryStatus,
                    from: directoryDescriptor,
                    rootDevice: rootDevice,
                    relativePath: childPath,
                    progress: &progress
                )
            } else {
                try removeNonDirectory(
                    named: name,
                    initialStatus: entryStatus,
                    from: directoryDescriptor,
                    rootDevice: rootDevice,
                    relativePath: childPath,
                    progress: &progress
                )
            }
        }
    }

    private func removeDirectory(
        named name: String,
        initialStatus: stat,
        from parentDescriptor: Int32,
        rootDevice: dev_t,
        relativePath: String,
        progress: inout DeletionProgress
    ) throws {
        let childDescriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard childDescriptor >= 0 else {
            throw DescriptorCleanupError.posix(
                operation: "openat directory",
                path: relativePath,
                code: errno
            )
        }

        do {
            var openedStatus = stat()
            guard fstat(childDescriptor, &openedStatus) == 0 else {
                throw DescriptorCleanupError.posix(
                    operation: "fstat directory",
                    path: relativePath,
                    code: errno
                )
            }
            guard sameObjectAndType(initialStatus, openedStatus) else {
                throw DescriptorCleanupError.identityChanged(path: relativePath)
            }
            guard openedStatus.st_dev == rootDevice else {
                throw DescriptorCleanupError.crossDeviceBoundary(path: relativePath)
            }

            try removeContents(
                of: childDescriptor,
                rootDevice: rootDevice,
                relativePath: relativePath,
                progress: &progress
            )
        } catch {
            Darwin.close(childDescriptor)
            throw error
        }
        Darwin.close(childDescriptor)

        try hooks.beforeRemovingEntry?(relativePath)
        let currentStatus = try revalidatedStatus(
            named: name,
            from: parentDescriptor,
            rootDevice: rootDevice,
            expected: initialStatus,
            relativePath: relativePath
        )
        guard isDirectory(currentStatus) else {
            throw DescriptorCleanupError.identityChanged(path: relativePath)
        }
        guard unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0 else {
            throw DescriptorCleanupError.posix(
                operation: "unlinkat directory",
                path: relativePath,
                code: errno
            )
        }
        progress.deletedAnyEntry = true
    }

    private func removeNonDirectory(
        named name: String,
        initialStatus: stat,
        from parentDescriptor: Int32,
        rootDevice: dev_t,
        relativePath: String,
        progress: inout DeletionProgress
    ) throws {
        try hooks.beforeRemovingEntry?(relativePath)
        let currentStatus = try revalidatedStatus(
            named: name,
            from: parentDescriptor,
            rootDevice: rootDevice,
            expected: initialStatus,
            relativePath: relativePath
        )
        guard !isDirectory(currentStatus) else {
            throw DescriptorCleanupError.identityChanged(path: relativePath)
        }
        guard unlinkat(parentDescriptor, name, 0) == 0 else {
            throw DescriptorCleanupError.posix(
                operation: "unlinkat",
                path: relativePath,
                code: errno
            )
        }

        let deletedBytes = isRegularFile(currentStatus)
            ? UInt64(max(0, currentStatus.st_size))
            : 0
        let (newTotal, overflow) = progress.estimatedDeletedBytes
            .addingReportingOverflow(deletedBytes)
        guard !overflow else {
            throw DescriptorCleanupError.estimatedSizeOverflow
        }
        progress.estimatedDeletedBytes = newTotal
        progress.deletedAnyEntry = true
    }

    private func revalidatedStatus(
        named name: String,
        from parentDescriptor: Int32,
        rootDevice: dev_t,
        expected: stat,
        relativePath: String
    ) throws -> stat {
        var currentStatus = stat()
        guard fstatat(
            parentDescriptor,
            name,
            &currentStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw DescriptorCleanupError.posix(
                operation: "fstatat before unlink",
                path: relativePath,
                code: errno
            )
        }
        guard currentStatus.st_dev == rootDevice else {
            throw DescriptorCleanupError.crossDeviceBoundary(path: relativePath)
        }
        guard sameObjectAndType(expected, currentStatus) else {
            throw DescriptorCleanupError.identityChanged(path: relativePath)
        }
        return currentStatus
    }

    private func entryNames(
        in directoryDescriptor: Int32,
        relativePath: String
    ) throws -> [String] {
        let duplicatedDescriptor = dup(directoryDescriptor)
        guard duplicatedDescriptor >= 0 else {
            throw DescriptorCleanupError.posix(
                operation: "dup directory",
                path: relativePath,
                code: errno
            )
        }
        guard let stream = fdopendir(duplicatedDescriptor) else {
            let code = errno
            Darwin.close(duplicatedDescriptor)
            throw DescriptorCleanupError.posix(
                operation: "fdopendir",
                path: relativePath,
                code: code
            )
        }
        defer { closedir(stream) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw DescriptorCleanupError.posix(
                        operation: "readdir",
                        path: relativePath,
                        code: errno
                    )
                }
                break
            }

            var nameBuffer = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: nameBuffer)
            let name = withUnsafePointer(to: &nameBuffer) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                throw DescriptorCleanupError.invalidEntryName(path: relativePath)
            }
            guard name != "." && name != ".." else {
                continue
            }
            names.append(name)
        }

        return names.sorted()
    }

    private func fingerprint(from value: stat) -> FileFingerprint {
        FileFingerprint(
            deviceID: UInt64(value.st_dev),
            fileID: UInt64(value.st_ino),
            ownerID: value.st_uid,
            sizeBytes: UInt64(max(0, value.st_size)),
            modifiedAt: Date(
                timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)
                    + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000
            )
        )
    }

    private func isDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR
    }

    private func isRegularFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG
    }

    private func sameObjectAndType(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_mode & S_IFMT == second.st_mode & S_IFMT
    }

    private func posixMessage(_ operation: String, path: String, code: Int32) -> String {
        String(describing: DescriptorCleanupError.posix(
            operation: operation,
            path: path,
            code: code
        ))
    }
}

private struct DeletionProgress {
    var estimatedDeletedBytes: UInt64 = 0
    var deletedAnyEntry = false
}

private enum DescriptorCleanupError: Error, CustomStringConvertible {
    case posix(operation: String, path: String, code: Int32)
    case pathRejected
    case identityChanged(path: String)
    case crossDeviceBoundary(path: String)
    case invalidEntryName(path: String)
    case estimatedSizeOverflow

    var description: String {
        switch self {
        case .posix(let operation, let path, let code):
            return "\(operation) failed for \(path): errno \(code)"
        case .pathRejected:
            return "Canonical directory path was replaced by an alias or symbolic link"
        case .identityChanged(let path):
            return "Entry identity changed before deletion: \(path)"
        case .crossDeviceBoundary(let path):
            return "Refused to cross device boundary: \(path)"
        case .invalidEntryName(let path):
            return "Refused an entry name that is not valid UTF-8 under: \(path)"
        case .estimatedSizeOverflow:
            return "Estimated deleted byte count overflowed UInt64"
        }
    }
}
