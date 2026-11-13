// ADR-059 — the secret words in the phone's password manager, channel
// `dev.sinhron/passwords` (`lib/core/account_access.dart`).
//
// Credential Manager: whichever provider the person uses (Google Password
// Manager, Samsung Pass, 1Password…). The entry belongs to this app — no
// domain needed. Google's is end-to-end encrypted and comes to a new phone
// with the Google account.
//   - `save {account, secret}` → the system save sheet; true = saved,
//     false = closed;
//   - `pick` → the person picks a saved entry; its password (the words)
//     comes back, or null.

package com.sinhron.sinhron

import android.app.Activity
import android.os.CancellationSignal
import androidx.core.content.ContextCompat
import androidx.credentials.CreateCredentialResponse
import androidx.credentials.CreatePasswordRequest
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPasswordOption
import androidx.credentials.PasswordCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object PasswordsBridge {
    const val CHANNEL = "dev.sinhron/passwords"

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        val manager = CredentialManager.create(activity)
        val main = ContextCompat.getMainExecutor(activity)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "save" -> {
                    val account = call.argument<String>("account")
                    val secret = call.argument<String>("secret")
                    if (account == null || secret == null) {
                        result.error("failed", "no value", null)
                        return@setMethodCallHandler
                    }
                    manager.createCredentialAsync(
                        activity,
                        CreatePasswordRequest(account, secret),
                        CancellationSignal(),
                        main,
                        object : CredentialManagerCallback<CreateCredentialResponse, CreateCredentialException> {
                            override fun onResult(response: CreateCredentialResponse) = result.success(true)

                            override fun onError(e: CreateCredentialException) {
                                // Never the secret in a message.
                                if (e is CreateCredentialCancellationException) result.success(false)
                                else result.error("failed", e.type, null)
                            }
                        },
                    )
                }
                "pick" -> manager.getCredentialAsync(
                    activity,
                    GetCredentialRequest(listOf(GetPasswordOption())),
                    CancellationSignal(),
                    main,
                    object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                        override fun onResult(response: GetCredentialResponse) =
                            result.success((response.credential as? PasswordCredential)?.password)

                        override fun onError(e: GetCredentialException) = result.success(null)
                    },
                )
                else -> result.notImplemented()
            }
        }
    }
}
