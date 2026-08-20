package com.rideguard.capture

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import com.rideguard.domain.model.Bounds
import com.rideguard.domain.model.ScreenSnapshot
import com.rideguard.domain.model.TextBlock

/**
 * Flattens an accessibility node tree into a [ScreenSnapshot].
 *
 * Deliberately iterative rather than recursive: offer cards are shallow, but
 * a malformed or hostile tree should never be able to blow the stack inside
 * a system-bound service that the user cannot easily kill.
 *
 * Both [AccessibilityNodeInfo.getText] and `contentDescription` are collected.
 * Driver apps frequently put the fare in one and the accessibility label in
 * the other, and which one is populated varies by app version — taking both
 * costs nothing and avoids a whole class of "it worked last week" bugs.
 */
object AccessibilityTreeReader {

    /** Guard rails. A real offer card is a few dozen nodes; anything near these is pathological. */
    private const val MAX_NODES = 600
    private const val MAX_DEPTH = 40

    fun read(
        root: AccessibilityNodeInfo?,
        packageName: String,
        capturedAtMs: Long,
    ): ScreenSnapshot {
        if (root == null) {
            return ScreenSnapshot(packageName, emptyList(), capturedAtMs)
        }

        val blocks = ArrayList<TextBlock>(64)
        val seen = HashSet<String>(64)
        val stack = ArrayDeque<Pair<AccessibilityNodeInfo, Int>>()
        stack.addLast(root to 0)
        var visited = 0

        val rect = Rect()

        while (stack.isNotEmpty() && visited < MAX_NODES) {
            val (node, depth) = stack.removeLast()
            visited++

            if (depth <= MAX_DEPTH) {
                for (i in 0 until node.childCount) {
                    val child = node.getChild(i) ?: continue
                    stack.addLast(child to depth + 1)
                }
            }

            if (!node.isVisibleToUser) continue

            node.getBoundsInScreen(rect)
            val bounds = Bounds(rect.left, rect.top, rect.right, rect.bottom)
            if (bounds.area <= 0) continue

            val viewId = node.viewIdResourceName

            for (raw in listOf(node.text, node.contentDescription)) {
                val text = raw?.toString()?.trim().orEmpty()
                if (text.isEmpty()) continue

                // Same string at the same place twice (text == contentDescription,
                // which is extremely common) is one block, not two.
                val key = "$text@${bounds.left},${bounds.top},${bounds.right},${bounds.bottom}"
                if (!seen.add(key)) continue

                blocks += TextBlock(text = text, bounds = bounds, viewId = viewId)
            }
        }

        return ScreenSnapshot(
            packageName = packageName,
            blocks = blocks,
            capturedAtMs = capturedAtMs,
        )
    }
}
