// ADR-058 — the Android side of `dev.sinhron/update`: the app updates itself
// from our server (not a store). Dart fetches android.json, downloads the APK
// and checks its SHA-256; here we say who installed us, which CPU we run on,
// read the downloaded APK's package / version / signing certificate, and
// hand it to the system installer (one "Install" tap — Android always asks).
//
//   info()                 → {installer, abis, is64, versionCode, packageName,
//                             certs (our own signing cert SHA-256s), canInstall}
//   inspect(path)          → {packageName, versionCode, certs} | null
//   canInstall()           → may Sinhron install apps ("unknown sources")
//   openInstallSettings()  → that switch in system Settings
//   install(path)          → the system installer for the file

package com.sinhron.sinhron

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/** Our own FileProvider class, so it never clashes with a plugin's. Shares
 *  only cacheDir/updates/ (res/xml/update_paths.xml). */
class UpdateFileProvider : FileProvider()

object AppUpdate {
    fun attach(context: Context, messenger: BinaryMessenger) {
        val ctx = context.applicationContext
        MethodChannel(messenger, "dev.sinhron/update").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(info(ctx))
                "inspect" -> result.success(call.argument<String>("path")?.let { inspect(ctx, it) })
                "canInstall" -> result.success(canInstall(ctx))
                "openInstallSettings" -> result.success(openInstallSettings(ctx))
                "install" -> result.success(call.argument<String>("path")?.let { install(ctx, it) } ?: false)
                else -> result.notImplemented()
            }
        }
    }

    private fun info(ctx: Context): Map<String, Any?> {
        val own = ownPackage(ctx)
        return mapOf(
            "installer" to installer(ctx),
            "abis" to Build.SUPPORTED_ABIS.toList(),
            // The same bitness as the APK installed now: switching between
            // the 32- and 64-bit APKs can look like a downgrade to Android
            // (split APK version codes differ by 1000 per CPU type).
            "is64" to android.os.Process.is64Bit(),
            "versionCode" to own?.let { versionCode(it) },
            "packageName" to ctx.packageName,
            "certs" to (own?.let { certs(it) } ?: emptyList<String>()),
            "canInstall" to canInstall(ctx),
        )
    }

    /** Who installed us: null / a package installer for an APK, a store's
     *  package (com.android.vending, …) otherwise. Dart decides. */
    private fun installer(ctx: Context): String? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            ctx.packageManager.getInstallSourceInfo(ctx.packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            ctx.packageManager.getInstallerPackageName(ctx.packageName)
        }
    } catch (e: Exception) {
        null
    }

    private fun ownPackage(ctx: Context): PackageInfo? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ctx.packageManager.getPackageInfo(ctx.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        } else {
            @Suppress("DEPRECATION")
            ctx.packageManager.getPackageInfo(ctx.packageName, PackageManager.GET_SIGNATURES)
        }
    } catch (e: Exception) {
        null
    }

    private fun inspect(ctx: Context, path: String): Map<String, Any?>? {
        if (!File(path).isFile) return null
        val pm = ctx.packageManager
        val p = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pm.getPackageArchiveInfo(path, PackageManager.GET_SIGNING_CERTIFICATES)
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageArchiveInfo(path, PackageManager.GET_SIGNATURES)
            }
        } catch (e: Exception) {
            null
        } ?: return null
        return mapOf(
            "packageName" to p.packageName,
            "versionCode" to versionCode(p),
            "certs" to certs(p),
        )
    }

    private fun versionCode(p: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) p.longVersionCode else @Suppress("DEPRECATION") p.versionCode.toLong()

    /** SHA-256 of each signing certificate, lower-case hex without colons. */
    private fun certs(p: PackageInfo): List<String> {
        val sigs: Array<Signature>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val si = p.signingInfo
            when {
                si == null -> null
                si.hasMultipleSigners() -> si.apkContentsSigners
                else -> si.signingCertificateHistory
            }
        } else {
            @Suppress("DEPRECATION")
            p.signatures
        }
        val md = MessageDigest.getInstance("SHA-256")
        return sigs.orEmpty().map { s -> md.digest(s.toByteArray()).joinToString("") { "%02x".format(it) } }
    }

    private fun canInstall(ctx: Context): Boolean = ctx.packageManager.canRequestPackageInstalls()

    /** Settings → "Install unknown apps" → Sinhron (Android 8+). */
    private fun openInstallSettings(ctx: Context): Boolean = try {
        ctx.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        true
    } catch (e: Exception) {
        false
    }

    /** The system installer for [path] (in cacheDir/updates/). If Sinhron
     *  may not install apps yet, the installer itself asks first ("allow
     *  from this source") and carries on after. */
    private fun install(ctx: Context, path: String): Boolean = try {
        val file = File(path)
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.updates", file)
        @Suppress("DEPRECATION")
        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
        true
    } catch (e: Exception) {
        false
    }
}
