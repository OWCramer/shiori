// Developer smoke test against live Steam CM servers.
//
//   steamkit-cli anon <appid>... [--fixtures <dir>]
//       Anonymous logon, licence list, PICS for the given apps; optionally writes
//       raw buffers as test fixtures.
//   steamkit-cli qr [seconds]
//       Starts a QR sign-in and prints the challenge URL. Nothing is stored.

import Foundation
@_spi(Debug) import SteamKit

let arguments = Array(CommandLine.arguments.dropFirst())
let session = SteamSession(
    configuration: SteamConfiguration(deviceName: "VN Hub CLI", deviceSeed: "steamkit-cli"),
    store: InMemorySessionStore()
)

func anonymous(_ args: [String]) async throws {
    var appIDs: [UInt32] = []
    var fixtures: URL?
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        if arg == "--fixtures", let dir = iterator.next() { fixtures = URL(fileURLWithPath: dir) }
        else if let id = UInt32(arg) { appIDs.append(id) }
    }

    try await session.logOnAnonymously()
    print("state:", await session.state)
    // Anonymous accounts get no licence list; 17906 is the public anonymous package.
    let licenses = (try? await session.licenses()) ?? [License(packageID: 17906)]
    print("licences:", licenses.map(\.packageID))

    let packages = try await session.packageInfo(for: licenses)
    for package in packages { print("package \(package.packageID): apps \(package.appIDs.prefix(10))") }

    for app in try await session.appInfo(appIDs) {
        print("app \(app.appID): \(app.name) [\(app.type)] change \(app.changeNumber)")
    }

    if let fixtures {
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let raw = try await session.rawProductInfo(apps: appIDs, packages: licenses)
        for (id, data) in raw.apps { try data.write(to: fixtures.appendingPathComponent("app_\(id).vdf")) }
        for (id, data) in raw.packages { try data.write(to: fixtures.appendingPathComponent("package_\(id).bin")) }
        print("wrote", raw.apps.count + raw.packages.count, "fixtures to", fixtures.path)
    }
    await session.signOut()
}

func qr(_ args: [String]) async throws {
    let seconds = args.first.flatMap(Double.init) ?? 15
    let task = Task {
        for try await event in session.beginQRSignIn() { print("qr:", event) }
    }
    try await Task.sleep(for: .seconds(seconds))
    task.cancel()
    print("cancelled after \(seconds)s; state:", await session.state)
}

do {
    switch arguments.first {
    case "anon": try await anonymous(Array(arguments.dropFirst()))
    case "qr": try await qr(Array(arguments.dropFirst()))
    default: print("usage: steamkit-cli anon <appid>... [--fixtures dir] | qr [seconds]")
    }
} catch {
    print("error:", error)
    exit(1)
}
