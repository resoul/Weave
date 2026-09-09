import Foundation
import Testing
import Weave

private struct DeepRoute: Route {
    let path: String
    let id: String
}

@MainActor
private final class GateState {
    var authenticated = false
}

private func deepLinkCodec() -> AnyRouteCodec<DeepRoute> {
    AnyRouteCodec(
        schemes: ["weave"],
        hosts: ["example.test"],
        decode: { url in
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let queryID = components.queryItems?.first(where: { $0.name == "id" })?.value,
                queryID == String(components.path.dropFirst())
            else { throw RouteCodecError.invalidRoute }
            let id = String(components.path.dropFirst())
            return DeepRoute(path: components.path, id: id)
        },
        encode: { route in
            var components = URLComponents()
            components.scheme = "weave"
            components.host = "example.test"
            components.path = "/\(route.id)"
            components.queryItems = [URLQueryItem(name: "id", value: route.id)]
            guard let url = components.url else { throw RouteCodecError.invalidURL }
            return url
        }
    )
}

@Test
func strictRouteCodecRoundTripsAndRejectsUntrustedURLs() throws {
    let codec = deepLinkCodec()
    let route = DeepRoute(path: "/home", id: "home")
    let url = try codec.encode(route)
    #expect(try codec.decode(url) == route)
    #expect(throws: RouteCodecError.unsupportedScheme("https")) {
        try codec.decode(URL(string: "https://example.test/home?id=home")!)
    }
    #expect(throws: RouteCodecError.unsupportedHost("evil.test")) {
        try codec.decode(URL(string: "weave://evil.test/home?id=home")!)
    }
    #expect(throws: RouteCodecError.invalidURL) {
        try codec.decode(URL(string: "weave://example.test/home?id=home#fragment")!)
    }
}

@Test
@MainActor
func deepLinkPipelineQueuesColdStartDeduplicatesAndAppliesGates() async throws {
    var routed: [DeepRoute] = []
    let gateState = GateState()
    let pipeline = DeepLinkPipeline(
        codec: deepLinkCodec(),
        capacity: 4,
        authenticationGate: { _ in gateState.authenticated },
        featureGate: { route in route.id != "disabled" },
        router: { route in
            routed.append(route)
            return true
        }
    )
    let homeURL = try deepLinkCodec().encode(DeepRoute(path: "/home", id: "home"))
    let home = DeepLinkRequest(url: homeURL)
    #expect(await pipeline.receive(home) == .queued(DeepRoute(path: "/home", id: "home")))
    #expect(await pipeline.receive(home) == .duplicate(DeepRoute(path: "/home", id: "home")))
    #expect(pipeline.pendingCount == 1)
    gateState.authenticated = true
    await pipeline.start()
    #expect(routed.map(\.id) == ["home"])
    #expect(await pipeline.receive(home) == .duplicate(DeepRoute(path: "/home", id: "home")))
}

@Test
func userActivityIsNormalizedWithoutConstructingAController() throws {
    let payload = UserActivityPayload(
        activityType: "com.example.open",
        webpageURL: URL(string: "weave://example.test/home?id=home"),
        userInfo: ["source": "test"])
    let request = try DeepLinkRequest(activity: payload)
    #expect(request.source == .userActivity)
    #expect(request.activity == payload)
}
