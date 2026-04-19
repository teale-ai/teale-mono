package com.teale.android.skills

import android.Manifest
import android.content.ContentResolver
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import com.teale.android.R
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Reads calendar events from the device's CalendarContract.Instances table.
 * Events are formatted as a short text summary suitable for injection as
 * system-prompt context before a chat message (e.g. "what's my week look like?").
 *
 * Gated on `READ_CALENDAR` — caller should request the permission first and
 * only use the skill after the user grants it.
 */
object CalendarSkill {

    fun hasPermission(ctx: Context): Boolean =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Return up to `maxEvents` upcoming events within the next `horizonDays`.
     * Each event: "{date} {start-end} · {title} [@ location]".
     */
    fun upcomingSummary(ctx: Context, horizonDays: Int = 7, maxEvents: Int = 20): String {
        if (!hasPermission(ctx)) return ctx.getString(R.string.calendar_permission_not_granted)
        val cr: ContentResolver = ctx.contentResolver
        val now = System.currentTimeMillis()
        val endMs = now + horizonDays.toLong() * 24L * 60 * 60 * 1000

        // Query the Instances table via the "byDay" URI which resolves recurrences.
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
            .appendPath(now.toString())
            .appendPath(endMs.toString())
            .build()

        val projection = arrayOf(
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.EVENT_LOCATION,
            CalendarContract.Instances.ALL_DAY,
        )
        val sort = "${CalendarContract.Instances.BEGIN} ASC"

        val out = StringBuilder()
        var count = 0
        val dayFmt = SimpleDateFormat("EEE MMM d", Locale.US).apply {
            timeZone = TimeZone.getDefault()
        }
        val hourFmt = SimpleDateFormat("h:mm a", Locale.US).apply {
            timeZone = TimeZone.getDefault()
        }
        val noTitle = ctx.getString(R.string.calendar_event_no_title)
        val allDayLabel = ctx.getString(R.string.calendar_event_all_day)
        cr.query(uri, projection, null, null, sort)?.use { c ->
            while (c.moveToNext() && count < maxEvents) {
                val title = c.getString(0).orEmpty().ifBlank { noTitle }
                val begin = c.getLong(1)
                val end = c.getLong(2)
                val location = c.getString(3)
                val allDay = c.getInt(4) != 0
                val day = dayFmt.format(Date(begin))
                val whenStr = if (allDay) allDayLabel else
                    "${hourFmt.format(Date(begin))} – ${hourFmt.format(Date(end))}"
                out.append(day).append(' ').append(whenStr).append(" · ").append(title)
                if (!location.isNullOrBlank()) {
                    out.append(" @ ").append(location)
                }
                out.append('\n')
                count++
            }
        }
        return if (count == 0) ctx.getString(R.string.calendar_empty_events, horizonDays)
        else ctx.getString(R.string.calendar_reference_header, horizonDays, out.toString().trim())
    }
}
