package de.sharedinbox.mua

import android.app.Activity
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.credentials.CreateCredentialResponse
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialNoCreateOptionException
import androidx.credentials.exceptions.CreateCredentialProviderConfigurationException
import androidx.credentials.exceptions.CreateCredentialUnsupportedException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.GetCredentialProviderConfigurationException
import androidx.credentials.exceptions.GetCredentialUnsupportedException
import androidx.credentials.exceptions.NoCredentialException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

/**
 * Passkeys with the WebAuthn PRF extension for the encrypted personal data
 * (`ENCRYPTED-OBJECTS.md` 4.2, `passkey-prf` slot), via Credential Manager.
 *
 * `create` and `get` take the WebAuthn request JSON (`requestJson`) as is
 * and return the response JSON; the PRF extension and its results travel
 * inside it. Errors are reported with the codes `cancelled`,
 * `noCredential`, `unsupported` and `failed`.
 *
 * Only exception types are logged — never request or response JSON, which
 * hold credential ids, salts and PRF outputs.
 */
class PasskeyBridge(messenger: BinaryMessenger, private val activity: Activity) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val credentialManager = CredentialManager.create(activity)
    private val mainExecutor = Executor { Handler(Looper.getMainLooper()).post(it) }

    init {
        channel.setMethodCallHandler { call, result ->
            val json = call.argument<String>("requestJson")
            when {
                call.method != "create" && call.method != "get" -> result.notImplemented()
                json == null -> result.error("failed", "missing requestJson", null)
                call.method == "create" -> create(json, result)
                else -> get(json, result)
            }
        }
    }

    private fun create(json: String, result: MethodChannel.Result) {
        credentialManager.createCredentialAsync(
            activity,
            CreatePublicKeyCredentialRequest(json),
            CancellationSignal(),
            mainExecutor,
            object : CredentialManagerCallback<CreateCredentialResponse, CreateCredentialException> {
                override fun onResult(response: CreateCredentialResponse) {
                    if (response !is CreatePublicKeyCredentialResponse) {
                        result.error("failed", "not a passkey response", null)
                        return
                    }
                    result.success(response.registrationResponseJson)
                }

                override fun onError(e: CreateCredentialException) {
                    val code = when (e) {
                        is CreateCredentialCancellationException -> "cancelled"
                        is CreateCredentialUnsupportedException,
                        is CreateCredentialProviderConfigurationException,
                        is CreateCredentialNoCreateOptionException,
                        -> "unsupported"
                        else -> "failed"
                    }
                    Log.i(TAG, "create failed: ${e.type} -> $code")
                    result.error(code, e.type, null)
                }
            },
        )
    }

    private fun get(json: String, result: MethodChannel.Result) {
        credentialManager.getCredentialAsync(
            activity,
            GetCredentialRequest(listOf(GetPublicKeyCredentialOption(json))),
            CancellationSignal(),
            mainExecutor,
            object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                override fun onResult(response: GetCredentialResponse) {
                    val credential = response.credential
                    if (credential !is PublicKeyCredential) {
                        result.error("failed", "not a passkey response", null)
                        return
                    }
                    result.success(credential.authenticationResponseJson)
                }

                override fun onError(e: GetCredentialException) {
                    val code = when (e) {
                        is GetCredentialCancellationException -> "cancelled"
                        is NoCredentialException -> "noCredential"
                        is GetCredentialUnsupportedException,
                        is GetCredentialProviderConfigurationException,
                        -> "unsupported"
                        else -> "failed"
                    }
                    Log.i(TAG, "get failed: ${e.type} -> $code")
                    result.error(code, e.type, null)
                }
            },
        )
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val TAG = "PasskeyBridge"
        const val CHANNEL = "de.sharedinbox.mua/passkey"
    }
}
