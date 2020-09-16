import Foundation
import MixinCrypto
import MixinServices

extension EdDSAMigration {
    
    static func migrate() {
        assert(!Thread.isMainThread)
        let key = Ed25519PrivateKey()
        let sessionSecret = key.publicKey.rawRepresentation.base64EncodedString()
        let result = AccountAPI.update(sessionSecret: sessionSecret)
        switch result {
        case .success(let response):
            guard let remotePublicKey = Data(base64Encoded: response.pinToken), let pinToken = AgreementCalculator.agreement(fromPublicKeyData: remotePublicKey, privateKeyData: key.x25519Representation) else {
                reporter.reportErrorToFirebase(MixinAPIError.invalidServerPinToken)
                waitAndRetry()
                return
            }
            AppGroupUserDefaults.Account.sessionSecret = nil
            AppGroupUserDefaults.Account.pinToken = nil
            AppGroupKeychain.sessionSecret = key.rfc8032Representation
            AppGroupKeychain.pinToken = pinToken
        case .failure(let error):
            reporter.reportErrorToFirebase(error)
            waitAndRetry()
        }
    }
    
    private static func waitAndRetry() {
        Thread.sleep(forTimeInterval: 2)
        migrate()
    }
    
}
