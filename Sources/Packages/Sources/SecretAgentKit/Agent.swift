import Foundation
import CryptoKit
import OSLog
import SecretKit
import AppKit

/// The `Agent` is an implementation of an SSH agent. It manages coordination and access between a socket, traces requests, notifies witnesses and passes requests to stores.
public class Agent {

    private let storeList: SecretStoreList
    private let witness: SigningWitness?
    private let writer = OpenSSHKeyWriter()
    private let requestTracer = SigningRequestTracer()

    /// Initializes an agent with a store list and a witness.
    /// - Parameters:
    ///   - storeList: The `SecretStoreList` to make available.
    ///   - witness: A witness to notify of requests.
    public init(storeList: SecretStoreList, witness: SigningWitness? = nil) {
        Logger().debug("Agent is running")
        self.storeList = storeList
        self.witness = witness
    }
    
}

extension Agent {

    /// Handles an incoming request.
    /// - Parameters:
    ///   - reader: A ``FileHandleReader`` to read the content of the request.
    ///   - writer: A ``FileHandleWriter`` to write the response to.
    /// - Return value: 
    ///   - Boolean if data could be read
    public func handle(reader: FileHandleReader, writer: FileHandleWriter) -> Bool {
        Logger().debug("Agent handling new data")
        let data = Data(reader.availableData)
        guard data.count > 4 else { return false}
        let requestTypeInt = data[4]
        guard let requestType = SSHAgent.RequestType(rawValue: requestTypeInt) else {
            writer.write(OpenSSHKeyWriter().lengthAndData(of: SSHAgent.ResponseType.agentFailure.data))
            Logger().debug("Agent returned \(SSHAgent.ResponseType.agentFailure.debugDescription)")
            return true
        }
        Logger().debug("Agent handling request of type \(requestType.debugDescription)")
        let subData = Data(data[5...])
        let response = handle(requestType: requestType, data: subData, reader: reader)
        writer.write(response)
        return true
    }

    func handle(requestType: SSHAgent.RequestType, data: Data, reader: FileHandleReader) -> Data {
        var response = Data()
        do {
            switch requestType {
            case .requestIdentities:
                response.append(SSHAgent.ResponseType.agentIdentitiesAnswer.data)
                response.append(identities())
                Logger().debug("Agent returned \(SSHAgent.ResponseType.agentIdentitiesAnswer.debugDescription)")
            case .signRequest:
                let provenance = requestTracer.provenance(from: reader)
                response.append(SSHAgent.ResponseType.agentSignResponse.data)
                response.append(try sign(data: data, provenance: provenance))
                Logger().debug("Agent returned \(SSHAgent.ResponseType.agentSignResponse.debugDescription)")
            }
        } catch {
            response.removeAll()
            response.append(SSHAgent.ResponseType.agentFailure.data)
            Logger().debug("Agent returned \(SSHAgent.ResponseType.agentFailure.debugDescription)")
        }
        let full = OpenSSHKeyWriter().lengthAndData(of: response)
        return full
    }

}

extension Agent {

    /// Lists the identities available for signing operations
    /// - Returns: An OpenSSH formatted Data payload listing the identities available for signing operations.
    func identities() -> Data {
        let secrets = storeList.stores.flatMap(\.secrets)
        var count = UInt32(secrets.count).bigEndian
        let countData = Data(bytes: &count, count: UInt32.bitWidth/8)
        var keyData = Data()
        let writer = OpenSSHKeyWriter()
        for secret in secrets {
            let keyBlob = writer.data(secret: secret)
            keyData.append(writer.lengthAndData(of: keyBlob))
            let curveData = writer.curveType(for: secret.algorithm, length: secret.keySize).data(using: .utf8)!
            keyData.append(writer.lengthAndData(of: curveData))
        }
        Logger().debug("Agent enumerated \(secrets.count) identities")
        return countData + keyData
    }

    /// Notifies witnesses of a pending signature request, and performs the signing operation if none object.
    /// - Parameters:
    ///   - data: The data to sign.
    ///   - provenance: A ``SecretKit.SigningRequestProvenance`` object describing the origin of the request.
    /// - Returns: An OpenSSH formatted Data payload containing the signed data response.
    func sign(data: Data, provenance: SigningRequestProvenance) throws -> Data {
        let reader = OpenSSHReader(data: data)
        let hash = reader.readNextChunk()
        guard let (store, secret) = secret(matching: hash) else {
            Logger().debug("Agent did not have a key matching \(hash as NSData)")
            throw AgentError.noMatchingKey
        }

        if let witness = witness {
            try witness.speakNowOrForeverHoldYourPeace(forAccessTo: secret, from: store, by: provenance)
        }

        let dataToSign = reader.readNextChunk()
        let signed = try store.sign(data: dataToSign, with: secret, for: provenance)
        let derSignature = signed.data

        let curveData = writer.curveType(for: secret.algorithm, length: secret.keySize).data(using: .utf8)!

        // Convert from DER formatted rep to raw (r||s)

        let rawRepresentation: Data
        switch (secret.algorithm, secret.keySize) {
        case (.ellipticCurve, 256):
            rawRepresentation = try CryptoKit.P256.Signing.ECDSASignature(derRepresentation: derSignature).rawRepresentation
        case (.ellipticCurve, 384):
            rawRepresentation = try CryptoKit.P384.Signing.ECDSASignature(derRepresentation: derSignature).rawRepresentation
        default:
            throw AgentError.unsupportedKeyType
        }


        let rawLength = rawRepresentation.count/2
        // Check if we need to pad with 0x00 to prevent certain
        // ssh servers from thinking r or s is negative
        let paddingRange: ClosedRange<UInt8> = 0x80...0xFF
        var r = Data(rawRepresentation[0..<rawLength])
        if paddingRange ~= r.first! {
            r.insert(0x00, at: 0)
        }
        var s = Data(rawRepresentation[rawLength...])
        if paddingRange ~= s.first! {
            s.insert(0x00, at: 0)
        }

        var signatureChunk = Data()
        signatureChunk.append(writer.lengthAndData(of: r))
        signatureChunk.append(writer.lengthAndData(of: s))

        var signedData = Data()
        var sub = Data()
        sub.append(writer.lengthAndData(of: curveData))
        sub.append(writer.lengthAndData(of: signatureChunk))
        signedData.append(writer.lengthAndData(of: sub))

        if let witness = witness {
            try witness.witness(accessTo: secret, from: store, by: provenance, requiredAuthentication: signed.requiredAuthentication)
        }

        Logger().debug("Agent signed request")

        return signedData
    }

}

extension Agent {

    /// Finds a ``Secret`` matching a specified hash whos signature was requested.
    /// - Parameter hash: The hash to match against.
    /// - Returns: A ``Secret`` and the ``SecretStore`` containing it, if a match is found.
    func secret(matching hash: Data) -> (AnySecretStore, AnySecret)? {
        storeList.stores.compactMap { store -> (AnySecretStore, AnySecret)? in
            let allMatching = store.secrets.filter { secret in
                hash == writer.data(secret: secret)
            }
            if let matching = allMatching.first {
                return (store, matching)
            }
            return nil
        }.first
    }

}


extension Agent {

    /// An error involving agent operations..
    enum AgentError: Error {
        case unhandledType
        case noMatchingKey
        case unsupportedKeyType
    }

}

extension SSHAgent.ResponseType {

    var data: Data {
        var raw = self.rawValue
        return  Data(bytes: &raw, count: UInt8.bitWidth/8)
    }

}
