package com.photosbackup.domain

import java.net.URI
import java.net.URLDecoder

object Policy {
    fun allowedGoogleUrl(value: String): Boolean =
        runCatching {
                val u = URI(value)
                u.scheme == "https" &&
                    u.userInfo == null &&
                    (u.port == -1 || u.port == 443) &&
                    u.host in
                        setOf(
                            "accounts.google.com",
                            "myaccount.google.com",
                            "www.google.com",
                            "accounts.youtube.com",
                        )
            }
            .getOrDefault(false)

    fun allowedGoogleResource(value: String): Boolean =
        runCatching {
                val u = URI(value)
                val host = u.host ?: return@runCatching false
                u.scheme == "https" &&
                    u.userInfo == null &&
                    (u.port == -1 || u.port == 443) &&
                    listOf(
                            "google.com",
                            "gstatic.com",
                            "googleusercontent.com",
                            "googleapis.com",
                            "youtube.com",
                        )
                        .any { host == it || host.endsWith(".$it") }
            }
            .getOrDefault(false)

    fun email(auth: String): String? =
        runCatching {
                auth
                    .split('&')
                    .map { it.split('=', limit = 2) }
                    .firstOrNull { it.size == 2 && it[0] == "Email" }
                    ?.get(1)
                    ?.let { URLDecoder.decode(it, "UTF-8") }
                    ?.takeIf { it.matches(Regex("""[^\s@]+@[^\s@]+\.[^\s@]+""")) }
            }
            .getOrNull()

    fun confirmed(eventType: String, mediaKey: String) =
        eventType == "item" && mediaKey.isNotBlank()
}
