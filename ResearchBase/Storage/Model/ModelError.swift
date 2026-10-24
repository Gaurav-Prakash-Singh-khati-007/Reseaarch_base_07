//
//  ModelError.swift
//  ResearchBase
//
//  Phase 1, Step 1B (F-06, F-08, F-09, F-10, F-13)
//
//  Every way the data model can say "no". Each case has a plain-words
//  description. A failed operation changes nothing (each public write
//  runs in one transaction).
//

import Foundation

enum ModelError: LocalizedError, Equatable {

    case notFound(kind: String, id: String)
    case emptyName
    case invalidValue(String)

    case tagNameTaken(String)
    case sameRecord

    case collectionCycle
    case collectionMissing(String)

    case citationKeyLocked(String)
    case citationKeyInUse(String)
    case citationKeyInvalid(String)

    case linkToSelf
    case linkTargetMissing(type: String, id: String)

    case fileMissing(String)
    case fileUnreadable(String)
    case storedFileDamaged(String)

    case invalidRule(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let kind, _):
            return "That \(kind) no longer exists."
        case .emptyName:
            return "A name cannot be empty."
        case .invalidValue(let what):
            return "That value is not allowed: \(what)."
        case .tagNameTaken(let name):
            return "A tag named “\(name)” already exists. Merge the two tags instead."
        case .sameRecord:
            return "Choose two different records to merge."
        case .collectionCycle:
            return "A folder cannot be moved inside itself or one of its own subfolders."
        case .collectionMissing:
            return "That folder no longer exists."
        case .citationKeyLocked(let key):
            return "The citation key “\(key)” is used by a draft. Changing it needs your confirmation."
        case .citationKeyInUse(let key):
            return "Another paper already uses the citation key “\(key)”."
        case .citationKeyInvalid(let key):
            return "“\(key)” cannot be used as a citation key. Use letters, digits and - _ : . only."
        case .linkToSelf:
            return "An item cannot be linked to itself."
        case .linkTargetMissing(let type, _):
            return "The \(type) you are linking to no longer exists."
        case .fileMissing(let name):
            return "The file “\(name)” could not be found."
        case .fileUnreadable(let name):
            return "The file “\(name)” could not be read."
        case .storedFileDamaged(let path):
            return "The stored file \(path) does not match its fingerprint. It was not changed."
        case .invalidRule(let why):
            return "This search rule cannot be used: \(why)."
        }
    }
}
