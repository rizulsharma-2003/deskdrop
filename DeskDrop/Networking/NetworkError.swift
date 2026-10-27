import Foundation

/// User-facing wording for transfer outcomes and errors. Raw errors stay in logs;
/// people see short, actionable sentences.
enum TransferMessages {
    static let stalled = String(localized: "The transfer stopped making progress.")

    static func outcome(for transfer: Transfer) -> String? {
        let peer = transfer.peerName
        let outgoing = transfer.direction == .outgoing
        switch transfer.phase {
        case .completed:
            return outgoing ? String(localized: "Delivered to \(peer).") : nil
        case .declined(let reason):
            switch reason {
            case .userDeclined, .expired:
                return outgoing ? String(localized: "\(peer) declined.") : String(localized: "You declined.")
            case .busy:
                return String(localized: "\(peer) has too many requests waiting. Try again shortly.")
            case .insufficientSpace:
                return String(localized: "\(peer)’s Mac doesn’t have enough free space.")
            case .destinationUnavailable:
                return String(localized: "\(peer)’s receiving folder isn’t available.")
            }
        case .expired:
            return outgoing ? String(localized: "\(peer) didn’t respond in time.") : String(localized: "This request expired.")
        case .cancelled(let source):
            switch source {
            case .local: return String(localized: "You cancelled this transfer.")
            case .remote: return String(localized: "\(peer) cancelled the transfer.")
            }
        case .failed(let reason):
            return failure(reason, peer: peer, outgoing: outgoing)
        default:
            return nil
        }
    }

    static func failure(_ reason: FailureReason, peer: String, outgoing: Bool) -> String {
        switch reason {
        case .peerDisconnected:
            return String(localized: "Lost the connection to \(peer).")
        case .peerUnavailable:
            return String(localized: "\(peer) isn’t reachable right now.")
        case .timedOut:
            return String(localized: "The transfer timed out.")
        case .fileUnavailable:
            return outgoing ? String(localized: "The file is no longer available.") : String(localized: "\(peer)’s file is no longer available.")
        case .fileChanged:
            return String(localized: "The file changed while it was being sent.")
        case .accessDenied:
            return String(localized: "DeskDrop doesn’t have permission to read the file.")
        case .destinationUnavailable:
            return outgoing ? String(localized: "\(peer)’s receiving folder isn’t available.") : String(localized: "Your receiving folder isn’t available.")
        case .insufficientSpace:
            return outgoing ? String(localized: "\(peer)’s Mac ran out of space.") : String(localized: "There isn’t enough free space.")
        case .validationFailed:
            return String(localized: "The files didn’t arrive intact, so they weren’t saved.")
        case .sendFailed:
            return String(localized: "The file couldn’t be sent.")
        case .receiveFailed:
            return String(localized: "The file couldn’t be received.")
        case .finalizeFailed:
            return outgoing ? String(localized: "\(peer)’s Mac couldn’t save the files.") : String(localized: "The files couldn’t be saved.")
        case .protocolError, .unknown:
            return String(localized: "Something went wrong with the transfer.")
        case .tooManyFiles:
            return String(localized: "Too many files for one transfer. Compress them into a .zip first.")
        case .duplicateTransfer:
            return String(localized: "This transfer was already received.")
        }
    }

    static func preparationFailure(_ error: Error) -> String {
        switch error as? PreparationError {
        case .nothingToSend:
            return String(localized: "There was nothing to send.")
        case .itemMissing(let name):
            return String(localized: "“\(name)” no longer exists.")
        case .unreadable(let name):
            return String(localized: "“\(name)” couldn’t be read.")
        case .unsupportedItem(let name):
            return String(localized: "“\(name)” isn’t a file or folder DeskDrop can send.")
        case .emptyFolder(let name):
            return String(localized: "“\(name)” is empty.")
        case .tooManyFiles:
            return String(localized: "Too many files (the limit is \(ProtocolLimits.maxFilesPerTransfer)). Compress them into a .zip first.")
        case .pathTooLong(let name):
            return String(localized: "“\(name)” is nested too deeply to send.")
        case .fileTooLarge(let name):
            return String(localized: "“\(name)” is too large to send.")
        case nil:
            return String(localized: "The files couldn’t be prepared.")
        }
    }

    static func destinationFailure(_ error: Error) -> String {
        switch error as? DestinationError {
        case .folderUnavailable(let name):
            return String(localized: "The receiving folder “\(name)” isn’t available. Choose another in Settings.")
        case .folderNotWritable(let name):
            return String(localized: "DeskDrop can’t save to “\(name)”. Choose another folder in Settings.")
        case .insufficientSpace(let required, let available):
            return String(localized: "Not enough free space: needs \(FileSizeFormatter.string(fromBytes: required)), \(FileSizeFormatter.string(fromBytes: available)) available.")
        case nil:
            if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
                return String(localized: "There isn’t enough free space.")
            }
            return String(localized: "The files couldn’t be saved to the receiving folder.")
        }
    }
}
