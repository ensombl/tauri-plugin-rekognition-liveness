package app.tauri.rekognitionliveness

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.content.res.Resources
import android.graphics.Color
import android.graphics.drawable.Drawable
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.AbstractComposeView
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.Permission
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import aws.smithy.kotlin.runtime.time.Instant
import com.amplifyframework.auth.AWSCredentials
import com.amplifyframework.auth.AWSCredentialsProvider
import com.amplifyframework.auth.AWSTemporaryCredentials
import com.amplifyframework.auth.AuthException
import com.amplifyframework.core.Consumer
import com.amplifyframework.ui.liveness.ui.Camera as AmplifyCamera
import com.amplifyframework.ui.liveness.ui.ChallengeOptions
import com.amplifyframework.ui.liveness.ui.FaceLivenessDetector
import com.amplifyframework.ui.liveness.ui.LivenessChallenge

@InvokeArg
class LivenessCredentialsArgs {
    lateinit var accessKeyId: String
    lateinit var secretAccessKey: String
    lateinit var sessionToken: String
    lateinit var expiresAt: String
}

@InvokeArg
class LivenessDisplayTextArgs {
    /** Overrides the SDK's "Center your face" prompt. */
    var centerFace: String? = null
}

@InvokeArg
class DetectLivenessArgs {
    lateinit var sessionId: String
    lateinit var region: String
    lateinit var credentials: LivenessCredentialsArgs

    /**
     * "front" (default) or "back". Only takes effect when the session was
     * created with `Settings.ChallengePreferences = [FaceMovementChallenge]`;
     * the default `FaceMovementAndLightChallenge` forces front regardless.
     * `var?` rather than `lateinit` because the JS caller may omit it.
     */
    var camera: String? = null

    /**
     * Optional UI-text overrides applied for the duration of this session.
     * Lets the consuming app re-word prompts that don't fit its context (e.g.
     * a rear-camera-at-the-gate flow re-wording "Center your face").
     */
    var displayText: LivenessDisplayTextArgs? = null
}

/**
 * Maps platform-neutral display-text keys (the names exposed on the
 * `displayText` JS arg) to Amplify Liveness Android string resource names.
 * Resource ids are looked up at runtime via `Resources.getIdentifier` —
 * library AAR `R.string` ids are remapped to consumer-app ids during
 * resource-merging at build time, so the consumer sees the same id the SDK
 * sees, and overriding `getString(id)` for that id wins everywhere.
 */
private val DISPLAY_TEXT_KEY_MAP = mapOf(
    "centerFace" to "amplify_ui_liveness_get_ready_center_face_label",
)

/**
 * Drop-in [Resources] subclass that returns caller-supplied strings for a
 * fixed set of resource ids and falls through to the wrapped resources for
 * everything else. Constructed once per session.
 *
 * The `Resources(AssetManager, DisplayMetrics, Configuration)` constructor
 * has been deprecated since API 18 with the guidance "apps should not
 * construct Resources directly", but Android has never offered a public
 * alternative for *subclassing* Resources — every framework / Compose
 * helper that needs to intercept string lookup ends up here. Suppression is
 * the canonical fix; behaviour is stable across all supported API levels.
 */
@Suppress("DEPRECATION")
private class StringOverrideResources(
    private val base: Resources,
    private val overrides: Map<Int, String>,
) : Resources(base.assets, base.displayMetrics, base.configuration) {
    override fun getString(id: Int): String =
        overrides[id] ?: super.getString(id)

    override fun getString(id: Int, vararg formatArgs: Any?): String =
        overrides[id]?.let { String.format(it, *formatArgs) }
            ?: super.getString(id, *formatArgs)

    override fun getText(id: Int): CharSequence =
        overrides[id] ?: super.getText(id)

    override fun getText(id: Int, def: CharSequence?): CharSequence =
        overrides[id] ?: super.getText(id, def)
}

/**
 * [ContextWrapper] that returns the [StringOverrideResources] above. We pass
 * an instance of this through Compose's `LocalContext` so the bundled
 * `FaceLivenessDetector` resolves `stringResource(...)` against our overrides
 * without the SDK needing to know the override mechanism exists.
 */
private class StringOverrideContext(
    base: Context,
    private val overrideResources: StringOverrideResources,
) : ContextWrapper(base) {
    override fun getResources(): Resources = overrideResources
}

/**
 * Build the override-id map from the caller's [LivenessDisplayTextArgs]. Any
 * key whose Android resource id can't be resolved (e.g. plugin built against
 * a newer SDK that renamed the string) is silently dropped.
 */
private fun resolveDisplayTextOverrides(
    context: Context,
    args: LivenessDisplayTextArgs?,
): Map<Int, String> {
    if (args == null) return emptyMap()
    val pairs = listOfNotNull(
        args.centerFace?.let { DISPLAY_TEXT_KEY_MAP["centerFace"] to it },
    )
    if (pairs.isEmpty()) return emptyMap()
    val pkg = context.packageName
    return pairs.mapNotNull { (name, value) ->
        if (name == null) return@mapNotNull null
        val id = context.resources.getIdentifier(name, "string", pkg)
        if (id == 0) null else id to value
    }.toMap()
}

/**
 * Hosts the Amplify [FaceLivenessDetector] composable as a sibling of the
 * Tauri WebView (mirrors the official barcode-scanner plugin pattern). All
 * camera capture and the WebSocket streaming connection to AWS Rekognition
 * Streaming live entirely native-side — only `{ status, error? }` crosses
 * back through the Tauri IPC bridge.
 */
@TauriPlugin(
    permissions = [
        Permission(strings = [Manifest.permission.CAMERA], alias = "camera"),
    ],
)
class RekognitionLivenessPlugin(private val activity: Activity) : Plugin(activity) {
    private lateinit var webView: WebView
    private var savedInvoke: Invoke? = null
    private var pendingArgs: DetectLivenessArgs? = null
    private var hostView: AbstractComposeView? = null
    private var webViewBackground: Drawable? = null
    private var backCallback: OnBackPressedCallback? = null
    private var lifecycleObserver: DefaultLifecycleObserver? = null
    private var cameraPermissionLauncher: ActivityResultLauncher<Array<String>>? = null

    override fun load(webView: WebView) {
        super.load(webView)
        this.webView = webView

        // Tauri 2.11.0 made `app.tauri.plugin.PluginManager` a singleton object
        // but its `requestPermissionsLauncher` (registered in `onActivityCreate`)
        // is never invoked by the runtime — so `Plugin.requestPermissionForAlias`
        // throws `lateinit property requestPermissionsLauncher has not been
        // initialized` on first use. We register our own ActivityResultLauncher
        // against the host activity's registry to bypass the broken wiring.
        // Tauri 2.10 doesn't have this issue (PluginManager was an instance
        // there, and TauriActivity constructed it during class init).
        (activity as? ComponentActivity)?.let { componentActivity ->
            cameraPermissionLauncher = componentActivity.activityResultRegistry.register(
                "rekognition-liveness:cameraPermission",
                ActivityResultContracts.RequestMultiplePermissions(),
            ) { result ->
                onCameraPermissionResult(result[Manifest.permission.CAMERA] == true)
            }
        }
    }

    @Command
    fun detectLiveness(invoke: Invoke) {
        if (savedInvoke != null) {
            invoke.reject("Another liveness session is already in progress")
            return
        }

        val args = invoke.parseArgs(DetectLivenessArgs::class.java)
        savedInvoke = invoke
        pendingArgs = args

        // Amplify's FaceLivenessDetector touches the camera the moment it
        // composes; if runtime CAMERA permission isn't granted we skip
        // straight to onError("CameraPermissionDeniedException"). Gate the
        // mount on a runtime permission check, requesting via the OS dialog
        // when needed (mirrors official tauri-plugin-barcode-scanner).
        if (isCameraPermissionGranted()) {
            activity.runOnUiThread { mountLivenessUi(args) }
        } else {
            val launcher = cameraPermissionLauncher
            if (launcher != null) {
                launcher.launch(arrayOf(Manifest.permission.CAMERA))
            } else {
                resolve(
                    "failed",
                    LivenessFailure(
                        code = "CameraPermissionDenied",
                        message = "Host activity is not a ComponentActivity; cannot request camera permission",
                    ),
                )
            }
        }
    }

    private fun onCameraPermissionResult(granted: Boolean) {
        // A `requestPermissions` JS call has priority over `detectLiveness`'s
        // implicit prompt — it expects a `{camera: ...}` payload back, not the
        // detection-result shape.
        pendingPermissionInvoke?.let { invoke ->
            pendingPermissionInvoke = null
            invoke.resolve(JSObject().apply {
                put("camera", if (granted) "granted" else "denied")
            })
            return
        }

        val args = pendingArgs
        if (granted && args != null) {
            activity.runOnUiThread { mountLivenessUi(args) }
        } else {
            resolve(
                "failed",
                LivenessFailure(
                    code = "CameraPermissionDenied",
                    message = "Camera permission is required for liveness detection",
                ),
            )
        }
    }

    private fun isCameraPermissionGranted(): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun cameraPermissionStateString(): String = when {
        isCameraPermissionGranted() -> "granted"
        // No way to reliably distinguish "denied forever" from "prompt" without
        // the activity context to call shouldShowRequestPermissionRationale,
        // and the result's only useful for caller UX hints. Keep it simple.
        else -> "prompt"
    }

    @Command
    override fun checkPermissions(invoke: Invoke) {
        invoke.resolve(JSObject().apply { put("camera", cameraPermissionStateString()) })
    }

    @Command
    override fun requestPermissions(invoke: Invoke) {
        if (isCameraPermissionGranted()) {
            invoke.resolve(JSObject().apply { put("camera", "granted") })
            return
        }
        val launcher = cameraPermissionLauncher
        if (launcher == null) {
            invoke.resolve(JSObject().apply { put("camera", "denied") })
            return
        }
        // Hijack the existing camera launcher: when the user responds, resolve
        // the JS-facing requestPermissions invoke instead of running the
        // detect-liveness mount path. We swap the callback by tagging
        // `pendingArgs == null` (no detection in flight) and intercepting the
        // result via a one-shot side-channel.
        pendingPermissionInvoke = invoke
        launcher.launch(arrayOf(Manifest.permission.CAMERA))
    }

    private var pendingPermissionInvoke: Invoke? = null

    private fun mountLivenessUi(args: DetectLivenessArgs) {
        val parent = webView.parent as ViewGroup
        webViewBackground = webView.background
        webView.setBackgroundColor(Color.TRANSPARENT)

        // We avoid `ComposeView(activity).apply { setContent { ... } }` because
        // the lambda's `Function0` bytecode does not match the runtime
        // `ComposeView.setContent(Function2<Composer, Int, Unit>)` ABI inside
        // the Tauri-bundled library module — Tauri's auto-generated consumer
        // app declares no `composeOptions`, and the cross-module compose
        // compiler handling silently drops our lambda transform. An
        // `AbstractComposeView` subclass with overridden `Content()` resolves
        // the call via virtual dispatch, sidestepping the lambda ABI entirely.
        val composeView = LivenessHostView(activity, args, this::resolve).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        parent.addView(composeView)
        hostView = composeView

        // Hardware-back must end the session, not pop the host activity.
        // onBackPressedDispatcher + lifecycle live on ComponentActivity, not
        // plain Activity — guard accordingly.
        (activity as? ComponentActivity)?.let { componentActivity ->
            backCallback = object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    resolve("cancelled", null)
                }
            }.also {
                componentActivity.onBackPressedDispatcher.addCallback(componentActivity, it)
            }

            lifecycleObserver = object : DefaultLifecycleObserver {
                override fun onPause(owner: LifecycleOwner) {
                    if (savedInvoke != null) resolve("cancelled", null)
                }
            }.also {
                componentActivity.lifecycle.addObserver(it)
            }
        }
    }

    @Synchronized
    private fun resolve(status: String, failure: LivenessFailure?) {
        val invoke = savedInvoke ?: return
        savedInvoke = null
        pendingArgs = null

        val payload = JSObject().apply {
            put("status", status)
            failure?.let {
                put(
                    "error",
                    JSObject().apply {
                        put("code", it.code)
                        put("message", it.message)
                    },
                )
            }
        }
        invoke.resolve(payload)
        teardown()
    }

    private fun teardown() {
        activity.runOnUiThread {
            hostView?.let { (it.parent as? ViewGroup)?.removeView(it) }
            hostView = null
            webViewBackground?.let { webView.background = it }
            webView.setBackgroundColor(Color.WHITE)
            webViewBackground = null

            backCallback?.remove()
            backCallback = null

            (activity as? ComponentActivity)?.let { componentActivity ->
                lifecycleObserver?.let { componentActivity.lifecycle.removeObserver(it) }
            }
            lifecycleObserver = null
        }
    }

    private data class LivenessFailure(val code: String, val message: String)

    /**
     * Hosts the Compose `FaceLivenessDetector` via an `AbstractComposeView`
     * subclass instead of `ComposeView.setContent { ... }`. The override goes
     * through virtual dispatch, so the runtime call site is fixed at the
     * override and unaffected by cross-module Compose compiler quirks that
     * leave the `setContent` lambda untransformed (`Function0` vs the expected
     * composer-aware `Function2`).
     */
    private class LivenessHostView(
        context: Context,
        private val args: DetectLivenessArgs,
        private val onResult: (status: String, failure: LivenessFailure?) -> Unit,
    ) : AbstractComposeView(context) {
        @Composable
        override fun Content() {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    // The session's challenge type (FaceMovementAndLight vs
                    // FaceMovement) is fixed when the backend calls
                    // `CreateFaceLivenessSession`; we don't pick it here. We
                    // do, however, supply the camera the SDK should use *if*
                    // the session ends up running FaceMovement — the
                    // FaceMovementAndLight path ignores any camera hint and
                    // forces front (the screen has to face the user for the
                    // light challenge to be meaningful).
                    val camera: AmplifyCamera = when (args.camera?.lowercase()) {
                        "back" -> AmplifyCamera.Back
                        else -> AmplifyCamera.Front
                    }
                    val challengeOptions = ChallengeOptions(
                        faceMovementAndLight = LivenessChallenge.FaceMovementAndLight,
                        faceMovement = LivenessChallenge.FaceMovement(camera = camera),
                    )

                    // Wrap LocalContext so the SDK's `stringResource(...)`
                    // calls resolve against caller-supplied overrides for the
                    // string ids we care about. No-op when displayText is
                    // unset / empty — Compose just sees the original context.
                    val baseContext = LocalContext.current
                    val overrideContext = remember(args.displayText) {
                        val overrides =
                            resolveDisplayTextOverrides(baseContext, args.displayText)
                        if (overrides.isEmpty()) baseContext
                        else StringOverrideContext(
                            baseContext,
                            StringOverrideResources(baseContext.resources, overrides),
                        )
                    }

                    CompositionLocalProvider(LocalContext provides overrideContext) {
                        FaceLivenessDetector(
                            sessionId = args.sessionId,
                            region = args.region,
                            credentialsProvider = StaticCredentialsProvider(args.credentials),
                            challengeOptions = challengeOptions,
                            onComplete = { onResult("success", null) },
                            onError = { error ->
                                onResult(
                                    "failed",
                                    LivenessFailure(
                                        code = error::class.simpleName ?: "FaceLivenessError",
                                        message = error.message ?: error.toString(),
                                    ),
                                )
                            },
                        )
                    }
                }
            }
        }
    }

    /**
     * Wraps the JS-supplied STS credentials in the callback-based provider
     * shape that Amplify Liveness expects (`com.amplifyframework.auth.AWSCredentialsProvider`,
     * not the Smithy coroutine variant). Plugin doesn't refresh — caller
     * must mint creds whose TTL outlives the session (≥5 minutes).
     */
    private class StaticCredentialsProvider(
        private val args: LivenessCredentialsArgs,
    ) : AWSCredentialsProvider<AWSCredentials> {
        override fun fetchAWSCredentials(
            onSuccess: Consumer<AWSCredentials>,
            onError: Consumer<AuthException>,
        ) {
            val expiration: Instant = try {
                Instant.fromIso8601(args.expiresAt)
            } catch (_: Exception) {
                // Fallback: 15 minutes from now if the ISO string didn't parse —
                // close to STS GetSessionToken's default TTL so behaviour is benign.
                Instant.fromEpochSeconds(System.currentTimeMillis() / 1000L + 15L * 60L)
            }
            // AWSTemporaryCredentials is a concrete final class, not an
            // interface — instantiate via its constructor.
            val creds = AWSTemporaryCredentials(
                accessKeyId = args.accessKeyId,
                secretAccessKey = args.secretAccessKey,
                sessionToken = args.sessionToken,
                expiration = expiration,
            )
            onSuccess.accept(creds)
        }
    }
}
