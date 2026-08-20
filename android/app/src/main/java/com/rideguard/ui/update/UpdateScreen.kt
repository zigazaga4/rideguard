package com.rideguard.ui.update

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rideguard.domain.update.UpdateCheck
import com.rideguard.ui.PrimaryButton
import com.rideguard.ui.RgColors
import com.rideguard.ui.SecondaryButton
import com.rideguard.ui.SectionHeader
import com.rideguard.update.UpdateController
import com.rideguard.update.UpdateUiState

/**
 * The update screen.
 *
 * RideGuard is distributed outside Google Play, so nothing else in the system
 * is ever going to tell this driver a new build exists. This screen is the
 * whole delivery mechanism, which means its failure modes matter more than its
 * happy path: every state below either offers a next action or explains, in
 * words a driver can act on, why there isn't one. "Something went wrong" is
 * not an acceptable terminal state when the alternative is a phone stuck on an
 * old build forever.
 */
@Composable
fun UpdateScreen(
    controller: UpdateController,
    onBack: () -> Unit,
) {
    val state by controller.state.collectAsState()
    val context = LocalContext.current

    // Check once on open. The driver came here to find out; making him tap
    // "check" first is a pointless extra step.
    LaunchedEffect(Unit) { controller.check() }

    // A 60 MB APK left in the cache after a successful install is pure waste on
    // a phone that is probably short of space.
    DisposableEffect(Unit) {
        onDispose { controller.clearCache() }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(RgColors.Background)
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        SectionHeader(
            title = "Updates",
            subtitle = "RideGuard installs itself from GitHub — it is not in the Play Store, " +
                "so nothing else will tell you when there is a new version.",
        )

        InstalledVersionCard(
            versionName = controller.currentVersionName,
            versionCode = controller.currentVersionCode,
        )

        when (val s = state) {
            is UpdateUiState.Idle -> {
                PrimaryButton("Check for updates") { controller.check() }
            }

            is UpdateUiState.Checking -> {
                StatusCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = RgColors.Good,
                        )
                        Spacer(Modifier.padding(horizontal = 6.dp))
                        Text("Checking GitHub…", color = RgColors.Secondary, fontSize = 13.sp)
                    }
                }
            }

            is UpdateUiState.UpToDate -> {
                StatusCard(accent = RgColors.Good) {
                    Text(
                        "You are on the latest version.",
                        color = RgColors.Primary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                SecondaryButton("Check again") { controller.check() }
            }

            is UpdateUiState.Available -> {
                AvailableCard(
                    versionName = s.release.versionName,
                    size = UpdateCheck.formatSize(s.release.sizeBytes),
                    notes = s.notes,
                    mandatory = s.mandatory,
                    unverified = s.release.sha256 == null,
                )
                PrimaryButton("Download and install") {
                    controller.downloadAndInstall(s.release)
                }
                SecondaryButton("Open GitHub releases") {
                    context.startActivity(controller.releasesPageIntent())
                }
            }

            is UpdateUiState.Downloading -> {
                StatusCard {
                    Text(
                        "Downloading ${s.release.versionName}…",
                        color = RgColors.Primary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.height(8.dp))
                    val fraction = s.fraction
                    if (fraction != null) {
                        LinearProgressIndicator(
                            progress = { fraction },
                            modifier = Modifier.fillMaxWidth(),
                            color = RgColors.Good,
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "${(fraction * 100).toInt()}% of ${UpdateCheck.formatSize(s.totalBytes) ?: "?"}",
                            color = RgColors.Secondary,
                            fontSize = 11.sp,
                        )
                    } else {
                        // No Content-Length — an indeterminate bar is honest,
                        // a fake percentage is not.
                        LinearProgressIndicator(
                            modifier = Modifier.fillMaxWidth(),
                            color = RgColors.Good,
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            UpdateCheck.formatSize(s.bytesRead) ?: "starting…",
                            color = RgColors.Secondary,
                            fontSize = 11.sp,
                        )
                    }
                }
                SecondaryButton("Cancel") { controller.cancel() }
            }

            is UpdateUiState.Installing -> {
                StatusCard {
                    Text(
                        "Android is asking you to confirm the install.",
                        color = RgColors.Primary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "If you don't see the dialog, pull down your notifications.",
                        color = RgColors.Secondary,
                        fontSize = 11.sp,
                        lineHeight = 15.sp,
                    )
                }
            }

            is UpdateUiState.Failed -> {
                StatusCard(accent = RgColors.Bad) {
                    Text(
                        s.message,
                        color = RgColors.Primary,
                        fontSize = 13.sp,
                        lineHeight = 18.sp,
                    )
                }
                if (s.retryable) {
                    PrimaryButton("Try again") { controller.check() }
                }
                if (!controller.canInstallUnknownApps()) {
                    SecondaryButton("Allow installing apps") {
                        context.startActivity(controller.unknownSourcesIntent())
                    }
                }
                // Always available. If the in-app path is broken, the driver
                // must still have a way to get the new build.
                SecondaryButton("Open GitHub releases") {
                    context.startActivity(controller.releasesPageIntent())
                }
            }
        }

        Spacer(Modifier.height(8.dp))
        SecondaryButton("Back", onClick = onBack)
    }
}

@Composable
private fun InstalledVersionCard(versionName: String, versionCode: Long) {
    StatusCard {
        Text("Installed", color = RgColors.Secondary, fontSize = 11.sp)
        Text(
            versionName,
            color = RgColors.Primary,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
        )
        Text("build $versionCode", color = RgColors.Secondary, fontSize = 11.sp)
    }
}

@Composable
private fun AvailableCard(
    versionName: String,
    size: String?,
    notes: String?,
    mandatory: Boolean,
    unverified: Boolean,
) {
    StatusCard(accent = RgColors.Good) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Version $versionName is available",
                color = RgColors.Primary,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
            )
            if (mandatory) {
                Spacer(Modifier.padding(horizontal = 4.dp))
                Badge("IMPORTANT", RgColors.Bad)
            }
        }
        size?.let {
            Text(
                "$it — this will use mobile data if you are not on Wi-Fi.",
                color = RgColors.Secondary,
                fontSize = 11.sp,
                lineHeight = 15.sp,
            )
        }
        notes?.takeIf { it.isNotBlank() }?.let {
            Spacer(Modifier.height(6.dp))
            Text(it, color = RgColors.Secondary, fontSize = 12.sp, lineHeight = 17.sp)
        }
        if (unverified) {
            // The digest is what proves the bytes that arrived are the bytes
            // that were published. Its absence is a publishing mistake, and
            // hiding that from the person about to install would be wrong.
            Spacer(Modifier.height(6.dp))
            Text(
                "This release was published without a checksum, so the download cannot be verified.",
                color = RgColors.Marginal,
                fontSize = 11.sp,
                lineHeight = 15.sp,
            )
        }
    }
}

@Composable
private fun Badge(label: String, color: Color) {
    Box(
        Modifier
            .clip(RoundedCornerShape(50))
            .background(color)
            .padding(horizontal = 7.dp, vertical = 2.dp),
    ) {
        Text(label, color = Color.White, fontSize = 9.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun StatusCard(
    accent: Color? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    // IntrinsicSize.Min lets the accent strip match whatever height the text
    // ends up being. A fixed dp would fall short the moment a failure message
    // wraps to three lines — which is exactly when the strip matters most.
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(RgColors.Surface)
            .height(IntrinsicSize.Min),
    ) {
        if (accent != null) {
            Box(
                Modifier
                    .width(4.dp)
                    .fillMaxHeight()
                    .background(accent),
            )
        }
        Column(Modifier.padding(16.dp), content = content)
    }
}
