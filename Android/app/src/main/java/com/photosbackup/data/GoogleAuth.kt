package com.photosbackup.data

import com.chaquo.python.Python
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.SecureRandom
import org.json.JSONObject

object GoogleAuth {
    private fun form(values: Map<String, String>) =
        values.toSortedMap().entries.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k,"UTF-8")}=${URLEncoder.encode(v,"UTF-8")}"
        }

    fun exchange(cookie: String): String {
        require(cookie.length in 16..8192 && !cookie.contains('\r') && !cookie.contains('\n'))
        val androidId =
            ByteArray(8)
                .also { SecureRandom().nextBytes(it) }
                .joinToString("") { "%02x".format(it) }
        val play = "38918a453d07199354f8b19af05ec6562ced5788"
        val body =
            form(
                mapOf(
                    "accountType" to "HOSTED_OR_GOOGLE",
                    "Email" to "oauth-token@example.com",
                    "has_permission" to "1",
                    "add_account" to "1",
                    "ACCESS_TOKEN" to "1",
                    "Token" to cookie,
                    "service" to "ac2dm",
                    "source" to "android",
                    "androidId" to androidId,
                    "device_country" to "us",
                    "operatorCountry" to "us",
                    "lang" to "en",
                    "sdk_version" to "17",
                    "google_play_services_version" to "240913000",
                    "client_sig" to play,
                    "callerSig" to play,
                    "droidguard_results" to "dummy123",
                )
            )
        val connection =
            URL("https://android.clients.google.com/auth").openConnection() as HttpURLConnection
        val values =
            try {
                connection.apply {
                    requestMethod = "POST"
                    connectTimeout = 30_000
                    readTimeout = 30_000
                    instanceFollowRedirects = false
                    doOutput = true
                    setRequestProperty("User-Agent", "GoogleAuth/1.4")
                    setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                    setRequestProperty("Accept-Encoding", "identity")
                }
                connection.outputStream.use { it.write(body.toByteArray()) }
                require(connection.responseCode == 200) { "Google refused the sign-in" }
                connection.inputStream
                    .use { input ->
                        val buffer = ByteArray(65536)
                        var size = 0
                        while (size < buffer.size) {
                            val count = input.read(buffer, size, buffer.size - size)
                            if (count < 0) break
                            size += count
                        }
                        String(buffer, 0, size)
                    }
                    .lineSequence()
                    .map { it.trim().split('=', limit = 2) }
                    .filter { it.size == 2 }
                    .associate { it[0] to it[1] }
            } finally {
                connection.disconnect()
            }
        require(
            !values.containsKey("Error") &&
                !values["Token"].isNullOrBlank() &&
                !values["Email"].isNullOrBlank()
        ) {
            "Google refused the sign-in"
        }
        val signature = "24bb24c05e47e0aefa68a58a766179d9b613a600"
        return form(
            mapOf(
                "androidId" to androidId,
                "app" to "com.google.android.apps.photos",
                "callerPkg" to "com.google.android.apps.photos",
                "callerSig" to signature,
                "client_sig" to signature,
                "device_country" to "us",
                "Email" to values.getValue("Email"),
                "google_play_services_version" to "240913000",
                "lang" to "en_US",
                "oauth2_foreground" to "1",
                "operatorCountry" to "us",
                "sdk_version" to "33",
                "service" to
                    "oauth2:openid https://www.googleapis.com/auth/mobileapps.native https://www.googleapis.com/auth/photos.native",
                "source" to "android",
                "Token" to values.getValue("Token"),
            )
        )
    }

    fun validate(auth: String): Boolean {
        val listener = AuthListener()
        Python.getInstance()
            .getModule("android_bridge")
            .callAttr(
                "run",
                JSONObject()
                    .put("command", "check-auth")
                    .put("auth_data", auth)
                    .put("timeout", 30)
                    .toString(),
                listener,
                java.util.concurrent.atomic.AtomicBoolean(false),
            )
        return listener.valid
    }
}

class AuthListener {
    var valid = false

    @Suppress("unused")
    fun event(raw: String) {
        if (JSONObject(raw).optString("type") == "auth") valid = true
    }
}
