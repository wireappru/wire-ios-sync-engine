//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import WireSystem

enum BuildType {
    case production
    case alpha
    case development
    case `internal`
    
    var certificateName: String {
        switch self {
        case .production:
            return "com.wire"
        case .alpha:
            return "com.wire.ent"
        case .development:
            return "com.wire.dev.ent"
        case .internal:
            return "com.wire.int.ent"
        }
    }
    
    var bundleID: String {
        switch self {
        case .production:
            return "com.wearezeta.zclient.ios"
        case .alpha:
            return "com.wearezeta.zclient-alpha"
        case .development:
            return "com.wearezeta.zclient.ios-development"
        case .internal:
            return "com.wearezeta.zclient.ios-internal"
        }
        
    }
}

extension ZMBackendEnvironmentType {
    var backendHost: String {
        switch self {
        case .production:
            return "prod-nginz-https.wire.com"
        case .staging:
            return "staging-nginz-https.zinfra.io"
        }
    }
    
    var websocketHost: String {
        switch self {
        case .production:
            return "prod-nginz-ssl.wire.com"
        case .staging:
            return "staging-nginz-ssl.zinfra.io"
        }
    }
    
    var frontendHost: String {
        switch self {
        case .production:
            return "wire.com"
        case .staging:
            return "staging-website.zinfra.io"
        }
    }
    
    var blacklistEndpoint: String {
        switch self {
        case .production:
            return "clientblacklist.wire.com/prod/ios"
        case .staging:
            return "clientblacklist.wire.com/staging/ios"
        }
    }
}

extension ZMBackendEnvironment {
    static func setupEnvironments() {
        [ZMBackendEnvironmentType.production, .staging].forEach {
            ZMBackendEnvironment.setupEnvironment(of: $0,
                                                  withBackendHost: $0.backendHost,
                                                  wsHost: $0.websocketHost,
                                                  blackListEndpoint: $0.blacklistEndpoint,
                                                  frontendHost: $0.frontendHost)
        }
        
        ZMAPNSEnvironment.setupForProduction(withCertificateName: BuildType.production.certificateName)
        [BuildType.alpha, .development, .internal].forEach {
            ZMAPNSEnvironment.setupForEnterprise(withBundleId: $0.bundleID, withCertificateName: $0.certificateName)
        }
    }
}
