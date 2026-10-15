package com.photosbackup.presentation

import android.annotation.SuppressLint
import android.net.http.SslError
import android.os.Bundle
import android.view.WindowManager
import android.webkit.*
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.lifecycleScope
import com.photosbackup.data.GoogleAuth
import com.photosbackup.data.Store
import com.photosbackup.domain.Policy
import kotlinx.coroutines.*

class SignInActivity : ComponentActivity() {
    private var web: WebView? = null
    private var checking = false
    private var ownsConnection = false
    private var message by
        mutableStateOf("Sign in on Google's page. Your password stays with Google.")
    private var job: Job? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (!Store.get(this).beginConnection()) {
            finish()
            return
        }
        ownsConnection = true
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        WebView.setWebContentsDebuggingEnabled(false)
        CookieManager.getInstance().removeAllCookies(null)
        setContent {
            BackupTheme {
                Surface {
                    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
                        Text(
                            "Connect Google Photos",
                            style = MaterialTheme.typography.titleLarge,
                            modifier = Modifier.padding(20.dp),
                        )
                        Text(message, modifier = Modifier.padding(horizontal = 20.dp))
                        TextButton(
                            onClick = { finish() },
                            modifier = Modifier.padding(horizontal = 12.dp),
                        ) {
                            Text("Cancel sign-in")
                        }
                        AndroidView(
                            factory = { context ->
                                WebView(context).apply {
                                    web = this
                                    settings.javaScriptEnabled = true
                                    settings.domStorageEnabled = true
                                    settings.allowFileAccess = false
                                    settings.allowContentAccess = false
                                    settings.mixedContentMode =
                                        WebSettings.MIXED_CONTENT_NEVER_ALLOW
                                    settings.setSupportMultipleWindows(false)
                                    settings.javaScriptCanOpenWindowsAutomatically = false
                                    settings.saveFormData = false
                                    CookieManager.getInstance()
                                        .setAcceptThirdPartyCookies(this, false)
                                    webViewClient =
                                        object : WebViewClient() {
                                            override fun shouldOverrideUrlLoading(
                                                view: WebView,
                                                request: WebResourceRequest,
                                            ): Boolean =
                                                !Policy.allowedGoogleUrl(request.url.toString())

                                            override fun shouldInterceptRequest(
                                                view: WebView,
                                                request: WebResourceRequest,
                                            ): WebResourceResponse? {
                                                return if (
                                                    Policy.allowedGoogleResource(
                                                        request.url.toString()
                                                    )
                                                )
                                                    null
                                                else
                                                    WebResourceResponse(
                                                        "text/plain",
                                                        "UTF-8",
                                                        java.io.ByteArrayInputStream(byteArrayOf()),
                                                    )
                                            }

                                            override fun onReceivedSslError(
                                                view: WebView,
                                                handler: SslErrorHandler,
                                                error: SslError,
                                            ) {
                                                handler.cancel()
                                                message =
                                                    "Google's secure page could not be verified."
                                            }

                                            override fun onPageFinished(
                                                view: WebView,
                                                url: String,
                                            ) {
                                                checkCookie()
                                            }
                                        }
                                    loadUrl("https://accounts.google.com/EmbeddedSetup")
                                }
                            },
                            modifier = Modifier.weight(1f).fillMaxWidth(),
                        )
                    }
                }
            }
        }
        job =
            lifecycleScope.launch {
                while (isActive) {
                    delay(1500)
                    checkCookie()
                }
            }
    }

    private fun checkCookie() {
        if (checking) return
        val token =
            CookieManager.getInstance()
                .getCookie("https://accounts.google.com")
                ?.split(';')
                ?.map { it.trim().split('=', limit = 2) }
                ?.firstOrNull { it.size == 2 && it[0] == "oauth_token" }
                ?.get(1) ?: return
        checking = true
        web?.stopLoading()
        message = "Checking your Google Photos account…"
        lifecycleScope.launch {
            try {
                val auth =
                    withContext(Dispatchers.IO) {
                        GoogleAuth.exchange(token).also { require(GoogleAuth.validate(it)) }
                    }
                Store.get(this@SignInActivity).connect(auth)
                finish()
            } catch (e: Exception) {
                message =
                    "Google Photos did not accept this sign-in. Close and retry, or use advanced credentials in Settings."
            } finally {
                CookieManager.getInstance().removeAllCookies(null)
                CookieManager.getInstance().flush()
            }
        }
    }

    override fun onDestroy() {
        if (ownsConnection) Store.get(this).endConnection()
        job?.cancel()
        web?.apply {
            stopLoading()
            clearHistory()
            clearCache(true)
            destroy()
        }
        web = null
        CookieManager.getInstance().removeAllCookies(null)
        CookieManager.getInstance().flush()
        WebStorage.getInstance().deleteAllData()
        super.onDestroy()
    }
}
