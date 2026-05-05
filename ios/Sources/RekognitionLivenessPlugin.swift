//
//  RekognitionLivenessPlugin.swift
//  tauri-plugin-rekognition-liveness
//
//  Hosts the AWS Amplify FaceLivenessDetectorView (SwiftUI) as a sibling of
//  the Tauri WKWebView (mirrors the official barcode-scanner plugin pattern).
//  Camera capture and the WebSocket streaming connection to AWS Rekognition
//  Streaming live entirely native-side — only `{ status, error? }` crosses
//  back through the Tauri IPC bridge.
//

import AVFoundation
import AWSPluginsCore
import FaceLiveness
import Foundation
import SwiftUI
import Tauri
import UIKit
import WebKit

class LivenessCredentialsArgs: Decodable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
    let expiresAt: String
}

class LivenessDisplayTextArgs: Decodable {
    /// Overrides the SDK's "Center your face" prompt.
    let centerFace: String?
}

class DetectLivenessArgs: Decodable {
    let sessionId: String
    let region: String
    let credentials: LivenessCredentialsArgs
    /// "front" (default) or "back". Only takes effect when the session was
    /// created with `Settings.ChallengePreferences = [FaceMovementChallenge]`;
    /// the default `FaceMovementAndLightChallenge` forces front regardless.
    let camera: String?
    /// Optional UI-text overrides applied for the duration of this session.
    let displayText: LivenessDisplayTextArgs?
}

/// Maps platform-neutral display-text keys (the names exposed on the
/// `displayText` JS arg) to the localizable keys Amplify Liveness Swift looks
/// up via `NSLocalizedString(... bundle: .main, ...)`. Anything not in this
/// map is silently ignored (forward-compat with future plugin keys the
/// vendored SDK doesn't yet honour).
private let displayTextKeyMap: [String: String] = [
    "centerFace": "amplify_ui_liveness_center_your_face_text"
]

/// Process-wide override store consulted by the `Bundle.localizedString`
/// swizzle below. Empty when no liveness session is active → swizzle becomes
/// a no-op (just calls through to the original implementation).
private final class LivenessLocalizedOverrides {
    static let shared = LivenessLocalizedOverrides()
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func set(_ overrides: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        values = overrides
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
    }

    func lookup(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
}

/// One-shot installer for the `Bundle.localizedString(forKey:value:table:)`
/// method swizzle. Without this, the Amplify SDK's `NSLocalizedString` calls
/// against `Bundle.main` only resolve from the host app's `Localizable.strings`
/// — runtime overrides have no path in. We swap the instance method for our
/// stub once at process start; the stub checks
/// `LivenessLocalizedOverrides.shared` first, then falls through to the
/// (now-renamed) original implementation. Idempotent via `dispatch_once`-style
/// static let.
private enum BundleLocalizedSwizzle {
    static let install: Void = {
        let cls: AnyClass = Bundle.self
        let original = #selector(Bundle.localizedString(forKey:value:table:))
        let replacement = #selector(Bundle.tplrl_localizedString(forKey:value:table:))
        guard
            let originalMethod = class_getInstanceMethod(cls, original),
            let replacementMethod = class_getInstanceMethod(cls, replacement)
        else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }()
}

extension Bundle {
    @objc fileprivate func tplrl_localizedString(
        forKey key: String,
        value: String?,
        table tableName: String?
    ) -> String {
        if let override = LivenessLocalizedOverrides.shared.lookup(key) {
            return override
        }
        // Post-swizzle this calls the *original* implementation thanks to
        // `method_exchangeImplementations` — naming notwithstanding.
        return self.tplrl_localizedString(forKey: key, value: value, table: tableName)
    }
}

class RekognitionLivenessPlugin: Plugin {
    private var savedInvoke: Invoke?
    private var hostingController: UIHostingController<AnyView>?
    private var willResignObserver: NSObjectProtocol?

    @objc public override func checkPermissions(_ invoke: Invoke) {
        invoke.resolve(["camera": currentCameraPermissionState()])
    }

    @objc public override func requestPermissions(_ invoke: Invoke) {
        let state = currentCameraPermissionState()
        if state == "prompt" {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                invoke.resolve(["camera": granted ? "granted" : "denied"])
            }
        } else {
            invoke.resolve(["camera": state])
        }
    }

    @objc public func detectLiveness(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(DetectLivenessArgs.self)

        if savedInvoke != nil {
            invoke.reject("Another liveness session is already in progress")
            return
        }

        // iOS aborts the process with a runtime exception when
        // AVCaptureDevice.requestAccess is called without an
        // NSCameraUsageDescription string in the host's Info.plist. Fail fast
        // with a clearer error before triggering the OS prompt.
        let entry = Bundle.main.infoDictionary?["NSCameraUsageDescription"] as? String
        if entry == nil || entry?.isEmpty == true {
            invoke.resolve([
                "status": "error",
                "error": [
                    "code": "MissingPermissionsString",
                    "message": "NSCameraUsageDescription is not set in the host app's Info.plist",
                ],
            ])
            return
        }

        savedInvoke = invoke

        // Mirror the Android pattern: gate the Amplify UI mount on a runtime
        // camera permission check. Amplify's FaceLivenessDetector grabs the
        // camera the instant it composes; without permission it short-circuits
        // to `onError(.cameraPermissionDenied)` and the user sees a confusing
        // "go to Settings" alert. Resolve permission first, then mount.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { [weak self] in self?.mountLivenessUi(args: args) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.mountLivenessUi(args: args)
                    } else {
                        self.resolve(
                            status: "failed",
                            error: ("CameraPermissionDenied",
                                    "Camera permission is required for liveness detection"))
                    }
                }
            }
        case .denied, .restricted:
            fallthrough
        @unknown default:
            resolve(
                status: "failed",
                error: ("CameraPermissionDenied",
                        "Camera permission is required for liveness detection"))
        }
    }

    private func currentCameraPermissionState() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return "granted"
        case .denied, .restricted:
            return "denied"
        case .notDetermined:
            return "prompt"
        @unknown default:
            return "prompt"
        }
    }

    private func mountLivenessUi(args: DetectLivenessArgs) {
        guard let viewController = self.manager.viewController,
              let webView = viewController.view.subviews.first(where: { $0 is WKWebView }) as? WKWebView,
              let parent = webView.superview else {
            resolve(status: "error", error: ("WebViewUnavailable",
                                            "Unable to locate the host WKWebView to mount the liveness UI."))
            return
        }

        // Install Bundle swizzle once, then load any caller-supplied UI-text
        // overrides for this session. Cleared in `teardown()` so the swizzle
        // becomes a no-op while no liveness UI is on screen.
        _ = BundleLocalizedSwizzle.install
        if let displayText = args.displayText {
            var overrides: [String: String] = [:]
            if let v = displayText.centerFace, let key = displayTextKeyMap["centerFace"] {
                overrides[key] = v
            }
            LivenessLocalizedOverrides.shared.set(overrides)
        } else {
            LivenessLocalizedOverrides.shared.clear()
        }

        let credentialsProvider = StaticAWSCredentialsProvider(args: args.credentials)

        // The session's challenge type (FaceMovementAndLight vs FaceMovement)
        // is fixed when the backend calls `CreateFaceLivenessSession`. We only
        // get to control which camera the SDK should use *if* the session
        // ends up running FaceMovement — FaceMovementAndLight forces the
        // front camera (the screen has to face the user for the light
        // challenge to mean anything).
        let livenessCamera: LivenessCamera = (args.camera?.lowercased() == "back") ? .back : .front
        let challengeOptions = ChallengeOptions(
            faceMovementChallengeOption: FaceMovementChallengeOption(camera: livenessCamera)
        )

        let livenessView = FaceLivenessDetectorView(
            sessionID: args.sessionId,
            credentialsProvider: credentialsProvider,
            region: args.region,
            challengeOptions: challengeOptions,
            isPresented: Binding<Bool>(
                get: { true },
                set: { _ in }
            ),
            onCompletion: { [weak self] result in
                switch result {
                case .success:
                    self?.resolve(status: "success", error: nil)
                case .failure(let err):
                    self?.resolve(status: "failed", error: ("FaceLivenessError", "\(err)"))
                }
            }
        )

        let host = UIHostingController(rootView: AnyView(livenessView))
        host.view.frame = parent.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = UIColor.clear
        parent.insertSubview(host.view, aboveSubview: webView)
        hostingController = host

        // Backgrounding mid-session → cancelled.
        willResignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resolve(status: "cancelled", error: nil)
        }
    }

    private func resolve(status: String, error: (String, String)?) {
        guard let invoke = savedInvoke else { return }
        savedInvoke = nil

        var payload: [String: Any] = ["status": status]
        if let (code, message) = error {
            payload["error"] = ["code": code, "message": message]
        }
        invoke.resolve(payload)

        DispatchQueue.main.async { [weak self] in
            self?.teardown()
        }
    }

    private func teardown() {
        hostingController?.view.removeFromSuperview()
        hostingController = nil

        if let observer = willResignObserver {
            NotificationCenter.default.removeObserver(observer)
            willResignObserver = nil
        }

        // Drop any per-session UI-text overrides — the next NSLocalizedString
        // call from anywhere in the host app falls through to the SDK / app
        // bundle as if the swizzle weren't there.
        LivenessLocalizedOverrides.shared.clear()
    }
}

/// Concrete `AWSTemporaryCredentials` carrier for STS-issued creds passed in
/// from JS. Amplify's `AWSCredentialsProvider` expects values matching the
/// `AWSCredentials` (or `AWSTemporaryCredentials`) protocol, not a struct
/// type — so we vend a minimal struct that conforms.
private struct StaticTemporaryCredentials: AWSTemporaryCredentials {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
    let expiration: Date
}

/// Static credentials provider wrapping the JS-supplied STS credentials.
/// Plugin doesn't refresh — caller must mint creds with TTL ≥ ~5 min so they
/// outlive the Liveness session (max ~3 min).
private struct StaticAWSCredentialsProvider: AWSCredentialsProvider {
    let args: LivenessCredentialsArgs

    func fetchAWSCredentials() async throws -> AWSCredentials {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiration = formatter.date(from: args.expiresAt)
            ?? ISO8601DateFormatter().date(from: args.expiresAt)
            ?? Date().addingTimeInterval(15 * 60)
        return StaticTemporaryCredentials(
            accessKeyId: args.accessKeyId,
            secretAccessKey: args.secretAccessKey,
            sessionToken: args.sessionToken,
            expiration: expiration
        )
    }
}

@_cdecl("init_plugin_rekognition_liveness")
func initPlugin() -> Plugin {
    return RekognitionLivenessPlugin()
}
