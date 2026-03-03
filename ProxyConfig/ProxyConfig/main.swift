import Foundation
import Security
import SystemConfiguration

let version = "0.4.0"

func main(_ args: [String]) {
    var port: Int = 0
    var flag: Bool = false
    
    if args.count > 2 {
        guard let _port = Int(args[1]) else {
            print("ERROR: port is invalid.")
            exit(EXIT_FAILURE)
        }
        guard args[2] == "enable" || args[2] == "disable" else {
            print("ERROR: flag is invalid.")
            exit(EXIT_FAILURE)
        }
        port = _port
        flag = args[2] == "enable"
    } else if args.count == 2 && args[1] == "version" {
        print(version)
        exit(EXIT_SUCCESS)
    } else {
        print("Usage: ProxyConfig <port> <enable/disable>")
        exit(EXIT_FAILURE)
    }
    
    var authRef: AuthorizationRef? = nil
    let authFlags: AuthorizationFlags = [.extendRights, .interactionAllowed, .preAuthorize]
    
    let authErr = AuthorizationCreate(nil, nil, authFlags, &authRef)
    
    guard authErr == noErr else {
        print("Error: Failed to create administration authorization due to error \(authErr).")
        exit(EXIT_FAILURE)
    }
    
    guard let authRef = authRef else {
        print("Error: No authorization has been granted to modify network configuration.")
        exit(EXIT_FAILURE)
    }
    
    if let prefRef = SCPreferencesCreateWithAuthorization(nil, "SpechtLite" as CFString, nil, authRef),
        let sets = SCPreferencesGetValue(prefRef, kSCPrefNetworkServices) as? NSDictionary {
        
        for rawKey in sets.allKeys {
            guard let key = rawKey as? String else {
                continue
            }

            let dict = sets.object(forKey: key) as? NSDictionary
            let hardware = ((dict?["Interface"]) as? NSDictionary)?["Hardware"] as? String
            if hardware == "AirPort" || hardware == "Ethernet" {
                let ip = flag ? "127.0.0.1" : ""
                let enableInt = flag ? 1 : 0
                
                var proxySettings: [String: Any] = [:]
                proxySettings[kCFNetworkProxiesHTTPProxy as String] = ip
                proxySettings[kCFNetworkProxiesHTTPEnable as String] = enableInt
                proxySettings[kCFNetworkProxiesHTTPSProxy as String] = ip
                proxySettings[kCFNetworkProxiesHTTPSEnable as String] = enableInt
                proxySettings[kCFNetworkProxiesSOCKSProxy as String] = ip
                proxySettings[kCFNetworkProxiesSOCKSEnable as String] = enableInt
                if flag {
                    proxySettings[kCFNetworkProxiesHTTPPort as String] = port
                    proxySettings[kCFNetworkProxiesHTTPSPort as String] = port
                    proxySettings[kCFNetworkProxiesSOCKSPort as String] = port + 1
                } else {
                    proxySettings.removeValue(forKey: kCFNetworkProxiesHTTPPort as String)
                    proxySettings.removeValue(forKey: kCFNetworkProxiesHTTPSPort as String)
                    proxySettings.removeValue(forKey: kCFNetworkProxiesSOCKSPort as String)
                }
                proxySettings[kCFNetworkProxiesExceptionsList as String] = [
                    "192.168.0.0/16",
                    "10.0.0.0/8",
                    "172.16.0.0/12",
                    "127.0.0.1",
                    "localhost",
                    "*.local"
                    ]
                
                let path = "/\(kSCPrefNetworkServices)/\(key)/\(kSCEntNetProxies)"
                SCPreferencesPathSetValue(prefRef, path as CFString, proxySettings as CFDictionary)
            }
        }
        
        SCPreferencesCommitChanges(prefRef)
        SCPreferencesApplyChanges(prefRef)
    }
    
    AuthorizationFree(authRef, [])
    
    exit(EXIT_SUCCESS)
}

main(CommandLine.arguments)
