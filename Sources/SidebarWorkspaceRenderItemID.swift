import CryptoKit
import Foundation

/// Stable, allocation-free identity for a `SidebarWorkspaceRenderItem`.
///
/// `ForEach` gathers row identifiers on every list diff, so the id must be
/// cheap to create and hash. Keep the discriminator as a byte so SwiftUI's
/// per-scroll list diff avoids enum-payload hash/equality witnesses.
struct SidebarWorkspaceRenderItemID: Hashable {
    private let kind: UInt8
    private let uuid: UUID

    static func group(_ uuid: UUID) -> Self {
        Self(kind: 1, uuid: uuid)
    }

    static func workspace(_ uuid: UUID) -> Self {
        Self(kind: 2, uuid: uuid)
    }

    static func remoteHostSection(_ uuid: UUID) -> Self {
        Self(kind: 3, uuid: uuid)
    }

    static func remoteTmuxWindow(_ uuid: UUID) -> Self {
        Self(kind: 4, uuid: uuid)
    }

    /// The agent inbox has at most one header row, so its identity is fixed.
    static func agentInboxHeader() -> Self {
        Self(kind: 5, uuid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5)))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.uuid == rhs.uuid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(uuid)
    }
}

/// Derives the stable row UUID for a remote tmux machine section from the
/// machine's endpoint identity (`RemoteTmuxHost.connectionHash`).
///
/// The UUID must be a pure function of the host key so the row keeps its
/// SwiftUI/AppKit identity across render passes, re-attaches, and app
/// launches (collapse state and scroll anchoring both key off it). The first
/// 16 bytes of a SHA-256 over the key give a collision-safe, deterministic
/// UUID without storing any registry.
enum SidebarRemoteHostSectionIdentity {
    static func uuid(forHostKey hostKey: String) -> UUID {
        let digest = SHA256.hash(data: Data(hostKey.utf8))
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in digest.enumerated() where index < 16 {
            bytes[index] = byte
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
