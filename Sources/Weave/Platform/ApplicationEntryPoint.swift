import Foundation
import WeaveUI
import WeaveAdapters

@MainActor
enum ApplicationEntryPoint {
    static func run<App: Application>(application: App) {
        let runtime = AppRuntime(application: application)
        #if canImport(UIKit)
            UIKitApplicationEntryPoint.run(runtime: runtime)
        #elseif canImport(AppKit)
            AppKitApplicationEntryPoint.run(runtime: runtime)
        #else
            _ = try? runtime.startSync()
            runtime.stop()
        #endif
    }
}

#if canImport(UIKit)
    import UIKit
    import UIKitAdapter

    @MainActor
    private enum UIKitApplicationEntryPoint {
        static func run<App: Application>(runtime: AppRuntime<App>) {
            // Text nodes are composed before window hosts are created. Bootstrap the adapter
            // first so convenience TextNode initializers use CoreText during composition.
            _ = UIKitAdapter()
            UIKitApplicationDelegate.makeWindows = { windowScene in
                if !runtime.isStarted {
                    _ = try? runtime.startSync()
                }
                return runtime.scenes.values.flatMap { scene in
                    scene.windows.map { window in
                        let nativeWindow = UIWindow(windowScene: windowScene)
                        let host = UIKitWindowHost(window: window, nativeWindow: nativeWindow)
                        _ = host.mount()
                        return host
                    }
                }
            }
            UIKitApplicationDelegate.stop = { runtime.stop() }
            _ = UIApplicationMain(
                CommandLine.argc,
                CommandLine.unsafeArgv,
                nil,
                NSStringFromClass(UIKitApplicationDelegate.self)
            )
            runtime.stop()
            UIKitApplicationDelegate.makeWindows = nil
            UIKitApplicationDelegate.stop = nil
        }
    }

    @MainActor
    private final class UIKitApplicationDelegate: NSObject, UIApplicationDelegate {
        static var makeWindows: (@MainActor (UIWindowScene) -> [UIKitWindowHost])?
        static var stop: (@MainActor () -> Void)?

        func application(
            _ application: UIApplication,
            configurationForConnecting connectingSceneSession: UISceneSession,
            options: UIScene.ConnectionOptions
        ) -> UISceneConfiguration {
            _ = application
            let configuration = UISceneConfiguration(
                name: "Weave",
                sessionRole: connectingSceneSession.role
            )
            configuration.delegateClass = UIKitWindowSceneDelegate.self
            return configuration
        }

        func applicationWillTerminate(_ application: UIApplication) {
            _ = application
            Self.stop?()
        }
    }

    @MainActor
    private final class UIKitWindowSceneDelegate: NSObject, UIWindowSceneDelegate {
        private var windows: [UIKitWindowHost] = []

        func scene(
            _ scene: UIScene,
            willConnectTo session: UISceneSession,
            options connectionOptions: UIScene.ConnectionOptions
        ) {
            _ = session
            _ = connectionOptions
            guard let windowScene = scene as? UIWindowScene,
                let makeWindows = UIKitApplicationDelegate.makeWindows
            else { return }
            windows = makeWindows(windowScene)
        }

        func sceneDidDisconnect(_ scene: UIScene) {
            _ = scene
            windows.forEach { $0.unmount() }
            windows.removeAll()
        }
    }

#elseif canImport(AppKit)
    import AppKit
    import AppKitAdapter

    @MainActor
    private enum AppKitApplicationEntryPoint {
        static func run<App: Application>(runtime: AppRuntime<App>) {
            // Text nodes are composed before window hosts are created. Bootstrap the adapter
            // first so convenience TextNode initializers use CoreText during composition.
            _ = AppKitAdapter()
            AppKitApplicationDelegate.makeWindows = {
                if !runtime.isStarted {
                    _ = try? runtime.startSync()
                }
                return runtime.scenes.values.flatMap { scene in
                    scene.windows.map { window in
                        let nativeWindow = NSWindow(
                            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered,
                            defer: false
                        )
                        let host = AppKitWindowHost(window: window, nativeWindow: nativeWindow)
                        _ = host.mount()
                        return host
                    }
                }
            }
            AppKitApplicationDelegate.stop = { runtime.stop() }
            let application = NSApplication.shared
            let delegate = AppKitApplicationDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.regular)
            application.activate(ignoringOtherApps: true)
            application.run()
            runtime.stop()
            AppKitApplicationDelegate.makeWindows = nil
            AppKitApplicationDelegate.stop = nil
        }
    }

    @MainActor
    private final class AppKitApplicationDelegate: NSObject, NSApplicationDelegate {
        static var makeWindows: (@MainActor () -> [AppKitWindowHost])?
        static var stop: (@MainActor () -> Void)?
        private var windows: [AppKitWindowHost] = []

        func applicationDidFinishLaunching(_ notification: Notification) {
            _ = notification
            guard let makeWindows = Self.makeWindows else { return }
            windows = makeWindows()
        }

        func applicationWillTerminate(_ notification: Notification) {
            _ = notification
            windows.forEach { $0.unmount() }
            windows.removeAll()
            Self.stop?()
        }
    }
#endif
