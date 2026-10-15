package com.photosbackup

import com.photosbackup.domain.Policy
import org.junit.Assert.*
import org.junit.Test

class PolicyTest {
    @Test
    fun credentialsNeedOneValidEmail() {
        assertEquals("a+b@example.com", Policy.email("Token=secret&Email=a%2Bb%40example.com"))
        assertNull(Policy.email("Email=bad%0Aaddress%40example.com"))
        assertNull(Policy.email("Token=secret"))
        assertNull(Policy.email("Email=not-an-address"))
    }

    @Test
    fun confirmationRequiresMediaKey() {
        assertFalse(Policy.confirmed("done", ""))
        assertFalse(Policy.confirmed("item", ""))
        assertFalse(Policy.confirmed("item_failed", "key"))
        assertTrue(Policy.confirmed("item", "google-media-key"))
    }

    @Test
    fun browserBoundaryRejectsLookalikesAndOtherSchemes() {
        listOf(
                "http://accounts.google.com/",
                "https://accounts.google.com.evil.test/",
                "https://accounts.google.com@evil.test/",
                "file:///etc/passwd",
                "javascript:alert(1)",
                "https://accounts.google.com:444/",
                "intent://accounts.google.com",
            )
            .forEach { assertFalse(it, Policy.allowedGoogleUrl(it)) }
        assertTrue(Policy.allowedGoogleUrl("https://accounts.google.com/EmbeddedSetup"))
    }

    @Test
    fun googleSubresourcesAreHttpsAndDomainBounded() {
        assertTrue(Policy.allowedGoogleResource("https://ssl.gstatic.com/accounts/logo.png"))
        assertFalse(Policy.allowedGoogleResource("https://ssl.gstatic.com.evil.test/"))
        assertFalse(Policy.allowedGoogleResource("http://ssl.gstatic.com/"))
        assertFalse(Policy.allowedGoogleResource("https://example.test/google.com"))
    }
}
